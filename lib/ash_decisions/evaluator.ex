# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Evaluator do
  @moduledoc """
  Evaluates a published decision, and records what it decided.

  ## The model is cached; the definition is not

  Evaluating a DMN document means handing the engine a loaded model, and loading one costs a
  parse plus an XSD validation that **shells out to `xmllint`** — a process spawn per
  evaluation, which is not a thing to do on a request path. So loaded models are memoised in
  `:persistent_term`, keyed by the definition's `content_hash`.

  The hash is the right key rather than the id, for a reason worth stating: a definition is
  immutable once published, so its hash and its content are the same fact. Keying on the id
  would be equally correct today and would quietly become wrong the moment anything learns to
  rewrite a draft in place.

  `:persistent_term` because the read is the hot path and the write happens once per
  definition; the global GC pause a write triggers is the documented cost, and paying it once
  per published decision is the right side of that trade. There is no eviction — the number of
  published definitions is bounded by deployment, not by traffic.

  ## What is recorded

  Each evaluation writes an `Evaluation` row: the decision, the definition's key and version,
  the inputs, the outputs and how long it took. That is the evidence an auditor asks for —
  and since the engine can say so, also **which rules fired**: `matched_rule_ids` is the
  engine's own account of the decision-table rules that matched the inputs, and `hit_policy`
  is the policy that reduced them to the answer. Both come from
  `Boxic.DMN.evaluate_with_trace/3` in the same pass that produces the value, so what is
  recorded is what decided, never a second opinion re-derived here.

  ## What is returned

  The result carries the same provenance, plus two things a caller acting on the answer needs
  and would otherwise have to re-derive:

    * `evaluation_id` — the id of the `Evaluation` row this call wrote, or `nil` when nothing
      was written (`record: false`, no `:evaluation_resource`, or a default-mode write that
      failed and was logged). A caller that cites the decision as evidence cites this row,
      without querying for it by correlation id afterwards.
    * `matched_rules` — `matched_rule_ids` resolved against the graph of the definition that
      was evaluated: each rule's `id`, its 1-based `position` in its table and its
      `description` (`nil` where the document gives none, or where the rule is not in the
      evaluated decision's table). Read from the same definition the engine ran, so a rule's
      words can never come from another version published in between.

  ## Declared inputs

  The engine refuses an input the decision requires through an `informationRequirement` and
  the caller did not supply. It does not refuse one the document declares as `inputData` but
  the decision's table reads without that edge — an authoring slip a designer makes easy — and
  that input evaluates as `null` into every rule that tests it: the table answers confidently
  about a value nobody gave it. `require_inputs: :declared` refuses that too: every `inputData`
  the document declares must be a key of `inputs` (an explicit `nil` counts as supplied). The
  refusal is an ordinary failed evaluation, `{:error, {:missing_inputs, definition_key, names}}`,
  recorded like any other. It is opt-in, because a document with several decisions may declare
  inputs that the one being asked for never reads.
  """

  require Logger

  alias AshDecisions.Dmn.Profile
  alias AshDecisions.Feel
  alias AshDecisions.Recorded

  @cache_prefix {__MODULE__, :model}
  @default_timeout_ms 1_000

  @typedoc "What an evaluation produced, plus the provenance of the thing that produced it."
  @type result :: %{
          outputs: term(),
          decision: String.t(),
          definition_key: String.t(),
          definition_version: integer(),
          duration_us: non_neg_integer(),
          matched_rule_ids: [String.t()],
          matched_rules: [matched_rule()],
          hit_policy: String.t() | nil,
          evaluation_id: term() | nil
        }

  @typedoc "A matched rule, resolved against the evaluated definition's graph."
  @type matched_rule :: %{
          id: String.t(),
          position: pos_integer() | nil,
          description: String.t() | nil
        }

  @doc """
  Evaluates `decision` in `definition` against `inputs`.

  `decision` may be omitted when the document defines exactly one; a document with several and
  no decision named is an error rather than a guess, because guessing means an author adding a
  second decision silently changes what every caller gets.

  Options:

    * `:decision` — the decision name to evaluate.
    * `:timeout` — milliseconds, default #{@default_timeout_ms}.
    * `:record` — write an `Evaluation` row. Default `true`: a failed write is logged and the
      answer is returned anyway. Pass `false` for a designer preview, which is a question about
      the model rather than a decision about a case. Pass `:required` on a governed path where
      an answer without its trace must not be acted on: a failed write (an error tuple or a
      raise) then fails the evaluation with `{:error, {:evaluation_not_recorded, reason}}`.
      A decision that already failed still returns its own error.
    * `:require_inputs` — `:declared` refuses the evaluation with
      `{:error, {:missing_inputs, definition_key, names}}` when an `inputData` the document
      declares is not a key of `inputs`. Default `nil`: a missing input evaluates as `null`.
    * `:evaluation_resource`, `:scope`, `:correlation_id` — how and where to record.
  """
  @spec evaluate(struct(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def evaluate(definition, inputs, opts \\ []) when is_map(inputs) do
    started = System.monotonic_time(:microsecond)

    with {:ok, model} <- model_for(definition),
         {:ok, decision} <- decision_name(definition, opts),
         :ok <- inputs_supplied(definition, inputs, opts),
         {:ok, outputs, trace} <- run(model, decision, inputs, opts) do
      result = %{
        outputs: outputs,
        decision: decision,
        definition_key: definition.key,
        definition_version: definition.version,
        duration_us: System.monotonic_time(:microsecond) - started,
        matched_rule_ids: trace.matched_rules,
        matched_rules: matched_rules(definition, decision, trace.matched_rules),
        hit_policy: hit_policy_string(trace.hit_policy),
        evaluation_id: nil
      }

      case record(definition, inputs, result, nil, opts) do
        {:ok, evaluation_id} -> {:ok, %{result | evaluation_id: evaluation_id}}
        {:error, _} = unrecorded -> unrecorded
      end
    else
      {:error, reason} = error ->
        # A failed evaluation is still evidence, and it names the decision it failed on
        # when that could be resolved. `decision_name/2` is a pure lookup over the graph,
        # so re-deriving it here cannot disagree with the run that failed.
        decision =
          case decision_name(definition, opts) do
            {:ok, name} -> name
            _ -> nil
          end

        _ = record(definition, inputs, failed_result(definition, decision, started), reason, opts)
        error
    end
  end

  defp failed_result(definition, decision, started) do
    %{
      outputs: nil,
      decision: decision,
      definition_key: definition.key,
      definition_version: definition.version,
      duration_us: System.monotonic_time(:microsecond) - started,
      matched_rule_ids: [],
      matched_rules: [],
      hit_policy: nil,
      evaluation_id: nil
    }
  end

  @doc "Like `evaluate/3`, raising on failure."
  @spec evaluate!(struct(), map(), keyword()) :: result()
  def evaluate!(definition, inputs, opts \\ []) do
    case evaluate(definition, inputs, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "decision #{definition.key} failed: #{inspect(reason)}"
    end
  end

  @doc """
  Drops the cached model for a definition, or the whole cache.

  Only useful in tests and after a hot upgrade that changes the engine: a published definition
  cannot change, so nothing else can invalidate an entry.
  """
  @spec flush_cache(struct() | :all) :: :ok
  def flush_cache(:all) do
    prefix = @cache_prefix

    for {key, _value} <- :persistent_term.get(),
        match?({^prefix, _}, key),
        do: :persistent_term.erase(key)

    :ok
  end

  def flush_cache(definition) do
    :persistent_term.erase({@cache_prefix, definition.content_hash})
    :ok
  end

  # ── model loading ────────────────────────────────────────────────────────

  defp model_for(%{content_hash: hash} = definition) when is_binary(hash) do
    case :persistent_term.get({@cache_prefix, hash}, :miss) do
      :miss -> load_and_cache(definition, hash)
      model -> {:ok, model}
    end
  end

  # A definition with no hash has not been through the create action -- a hand-built struct in
  # a test, most likely. Load it, but do not cache it: there is no key that means anything.
  defp model_for(definition), do: load(definition)

  defp load_and_cache(definition, hash) do
    case load(definition) do
      {:ok, model} ->
        :persistent_term.put({@cache_prefix, hash}, model)
        {:ok, model}

      error ->
        error
    end
  end

  defp load(%{xml: xml}) when is_binary(xml) do
    # Normalized on the way in, never on the way to storage. See `AshDecisions.Dmn.Profile`:
    # the designer writes DMN 1.3 and the engine loads only 1.5.
    case xml |> Profile.normalize() |> Boxic.DMN.load_xml() do
      {:ok, model} -> {:ok, model}
      {:error, reason} -> {:error, {:model_load_failed, reason}}
    end
  rescue
    e -> {:error, {:model_load_raised, Exception.message(e)}}
  end

  defp load(_definition), do: {:error, :no_xml}

  # ── which decision ───────────────────────────────────────────────────────

  defp decision_name(definition, opts) do
    case Keyword.get(opts, :decision) do
      name when is_binary(name) ->
        {:ok, name}

      nil ->
        case names(definition) do
          [only] ->
            {:ok, only}

          [] ->
            {:error, {:no_decisions, definition.key}}

          many ->
            # Not a guess. An author adding a second decision would otherwise silently change
            # what every existing caller receives.
            {:error, {:ambiguous_decision, definition.key, many}}
        end
    end
  end

  defp names(%{graph: %{"decisions" => decisions}}) when is_map(decisions) do
    decisions |> Map.values() |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)
  end

  defp names(_definition), do: []

  # ── declared inputs ──────────────────────────────────────────────────────

  defp inputs_supplied(definition, inputs, opts) do
    case Keyword.get(opts, :require_inputs) do
      nil ->
        :ok

      :declared ->
        # The keys the engine will see: `Feel.to_feel_value/1` stringifies them and drops a
        # value that was never loaded, which is not a value anyone supplied.
        supplied = Feel.to_feel_value(inputs)

        case Enum.reject(declared_inputs(definition), &Map.has_key?(supplied, &1)) do
          [] -> :ok
          missing -> {:error, {:missing_inputs, definition.key, missing}}
        end

      other ->
        raise ArgumentError,
              "unknown :require_inputs option #{inspect(other)}; expected :declared or nil"
    end
  end

  defp declared_inputs(%{graph: %{"input_data" => input_data}}) when is_map(input_data) do
    input_data
    |> Map.values()
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp declared_inputs(_definition), do: []

  # ── matched rules ────────────────────────────────────────────────────────

  # Resolved against the graph of the definition that was just evaluated, never one read
  # again afterwards: the rule's words must belong to the version whose rule decided.
  defp matched_rules(definition, decision, rule_ids) do
    rules = decision_rules(definition, decision)

    for id <- rule_ids do
      case Enum.find_index(rules, &(&1["id"] == id)) do
        nil -> %{id: id, position: nil, description: nil}
        index -> %{id: id, position: index + 1, description: Enum.at(rules, index)["description"]}
      end
    end
  end

  defp decision_rules(%{graph: %{"decisions" => decisions}}, decision) when is_map(decisions) do
    decisions
    |> Map.values()
    |> Enum.find(%{}, &(&1["name"] == decision))
    |> Map.get("rules", [])
  end

  defp decision_rules(_definition, _decision), do: []

  # ── evaluation ───────────────────────────────────────────────────────────

  # Bounded the same way `AshDecisions.Feel` bounds an expression, and for the same reason: a
  # decision table is authored by a tenant admin, and a document that takes forever to evaluate
  # is a denial of service with a friendly name.
  defp run(model, decision, inputs, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    context = Feel.to_feel_value(inputs)

    task = Task.async(fn -> Boxic.DMN.evaluate_with_trace(model, decision, context) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, outputs, trace}} -> {:ok, outputs, trace}
      {:ok, {:error, reason}} -> {:error, {:evaluation_failed, reason}}
      {:exit, reason} -> {:error, {:evaluation_crashed, reason}}
      nil -> {:error, {:evaluation_timeout, timeout}}
    end
  end

  # The engine traces the hit policy as an atom (`:priority`); the resource stores the DMN
  # spelling (`"PRIORITY"`), the same form the definition's graph carries. The atom set is
  # fixed by the engine's loader, so the round trip is exact.
  defp hit_policy_string(nil), do: nil

  defp hit_policy_string(policy) when is_atom(policy),
    do: policy |> Atom.to_string() |> String.upcase()

  # ── evidence ─────────────────────────────────────────────────────────────

  defp record(definition, inputs, result, error, opts) do
    resource = Keyword.get(opts, :evaluation_resource)

    mode = Keyword.get(opts, :record, true)

    if mode in [true, :required] and resource do
      scope = Keyword.get(opts, :scope, %AshDecisions.Scope{})
      attrs = evaluation_attrs(definition, inputs, result, error, opts)

      case resource.create(attrs, AshDecisions.Scope.engine(scope)) do
        {:error, reason} -> unrecorded(mode, reason)
        written -> {:ok, written_id(written)}
      end
    else
      {:ok, nil}
    end
  rescue
    e -> unrecorded(Keyword.get(opts, :record, true), e)
  end

  # By default evidence must not be able to fail the decision it is evidence of: a decision
  # that answered correctly and could not be written down is a logging problem, and turning
  # it into a routing failure would be a worse one. `record: :required` is the caller saying
  # the opposite, because on its path an answer nobody can audit must not be acted on.
  defp unrecorded(:required, reason), do: {:error, {:evaluation_not_recorded, reason}}

  defp unrecorded(_mode, reason) do
    Logger.warning("ash_decisions: could not record evaluation: #{describe(reason)}")
    {:ok, nil}
  end

  # A code interface `create` answers `{:ok, record}`; a hand-written store may answer the
  # record itself. Anything else wrote a row nobody can point at.
  defp written_id({:ok, %{id: id}}), do: id
  defp written_id(%{id: id}), do: id
  defp written_id(_written), do: nil

  defp describe(%{__exception__: true} = e), do: Exception.message(e)
  defp describe(other), do: inspect(other, limit: 5)

  defp evaluation_attrs(definition, inputs, result, error, opts) do
    %{
      definition_id: Map.get(definition, :id),
      definition_key: result.definition_key,
      definition_version: result.definition_version,
      decision_id: result.decision,
      inputs: Recorded.encode(inputs),
      # Nil-checked, not truthy-checked: an explicit `false` is an answer to record.
      outputs:
        if(is_nil(result.outputs), do: nil, else: Recorded.encode(%{"value" => result.outputs})),
      # From the same engine pass that produced the outputs: which decision-table rules
      # matched, and the hit policy that reduced them. See the moduledoc.
      matched_rule_ids: result.matched_rule_ids,
      hit_policy: result.hit_policy,
      duration_us: result.duration_us,
      error: error && %{"reason" => inspect(error, limit: 5)},
      correlation_id: Keyword.get(opts, :correlation_id)
    }
  end
end

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

  ## What is recorded, and one thing that is not

  Each evaluation writes an `Evaluation` row: the decision, the definition's key and version,
  the inputs, the outputs and how long it took. That is the evidence an auditor asks for.

  **Which rule fired is not recorded**, and the reason is a limitation rather than an
  oversight: `Boxic.DMN.evaluate/3` returns the decision's value and nothing about how it
  reached it. We could re-evaluate every input entry against the inputs ourselves and report
  the rules *we* think matched — and that second opinion could disagree with the engine's,
  which is worse than not answering. The field stays empty until the engine can say, and the
  moment it can, the column is already there.
  """

  require Logger

  alias AshDecisions.Feel

  @cache_prefix {__MODULE__, :model}
  @default_timeout_ms 1_000

  @typedoc "What an evaluation produced, plus the provenance of the thing that produced it."
  @type result :: %{
          outputs: term(),
          decision: String.t(),
          definition_key: String.t(),
          definition_version: integer(),
          duration_us: non_neg_integer()
        }

  @doc """
  Evaluates `decision` in `definition` against `inputs`.

  `decision` may be omitted when the document defines exactly one; a document with several and
  no decision named is an error rather than a guess, because guessing means an author adding a
  second decision silently changes what every caller gets.

  Options:

    * `:decision` — the decision name to evaluate.
    * `:timeout` — milliseconds, default #{@default_timeout_ms}.
    * `:record` — write an `Evaluation` row. Default `true`; pass `false` for a designer
      preview, which is a question about the model rather than a decision about a case.
    * `:evaluation_resource`, `:scope`, `:correlation_id` — how and where to record.
  """
  @spec evaluate(struct(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def evaluate(definition, inputs, opts \\ []) when is_map(inputs) do
    started = System.monotonic_time(:microsecond)

    with {:ok, model} <- model_for(definition),
         {:ok, decision} <- decision_name(definition, opts),
         {:ok, outputs} <- run(model, decision, inputs, opts) do
      result = %{
        outputs: outputs,
        decision: decision,
        definition_key: definition.key,
        definition_version: definition.version,
        duration_us: System.monotonic_time(:microsecond) - started
      }

      record(definition, inputs, result, nil, opts)
      {:ok, result}
    else
      {:error, reason} = error ->
        record(definition, inputs, nil, reason, opts)
        error
    end
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
    case xml |> AshDecisions.Dmn.Profile.normalize() |> Boxic.DMN.load_xml() do
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

  # ── evaluation ───────────────────────────────────────────────────────────

  # Bounded the same way `AshDecisions.Feel` bounds an expression, and for the same reason: a
  # decision table is authored by a tenant admin, and a document that takes forever to evaluate
  # is a denial of service with a friendly name.
  defp run(model, decision, inputs, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    context = Feel.to_feel_value(inputs)

    task = Task.async(fn -> Boxic.DMN.evaluate(model, decision, context) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, outputs}} -> {:ok, outputs}
      {:ok, {:error, reason}} -> {:error, {:evaluation_failed, reason}}
      {:exit, reason} -> {:error, {:evaluation_crashed, reason}}
      nil -> {:error, {:evaluation_timeout, timeout}}
    end
  end

  # ── evidence ─────────────────────────────────────────────────────────────

  defp record(definition, inputs, result, error, opts) do
    resource = Keyword.get(opts, :evaluation_resource)

    if Keyword.get(opts, :record, true) and resource do
      scope = Keyword.get(opts, :scope, %AshDecisions.Scope{})

      attrs = %{
        definition_id: Map.get(definition, :id),
        definition_key: definition.key,
        definition_version: definition.version,
        decision_id: result && result.decision,
        inputs: jsonable(inputs),
        outputs: result && jsonable(%{"value" => result.outputs}),
        # See the moduledoc: the engine does not report which rules matched, and a second
        # opinion computed here could disagree with the one that actually decided.
        matched_rule_ids: [],
        duration_us: result && result.duration_us,
        error: error && %{"reason" => inspect(error, limit: 5)},
        correlation_id: Keyword.get(opts, :correlation_id)
      }

      resource.create(attrs, AshDecisions.Scope.engine(scope))
    end
  rescue
    # Evidence must not be able to fail the decision it is evidence of. A decision that
    # answered correctly and could not be written down is a logging problem, and turning it
    # into a routing failure would be a worse one.
    e ->
      Logger.warning("ash_decisions: could not record evaluation: #{Exception.message(e)}")
      :ok
  end

  # Whatever the engine returned has to survive a jsonb round trip. Decimals in particular
  # encode as strings rather than losing precision to a float.
  defp jsonable(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp jsonable(%{__struct__: _} = value), do: inspect(value)

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value) when is_atom(value) and not is_boolean(value), do: to_string(value)
  defp jsonable(value), do: value
end

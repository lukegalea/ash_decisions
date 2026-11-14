# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Replay do
  @moduledoc """
  What a candidate version would have decided, case by case, before anyone relies on it.

  `AshDecisions.Diff` says what changed in a decision's tables. This says what that change
  does to real cases: it re-runs the inputs of recorded `Evaluation` rows against a candidate
  version and compares the answer and the rules that matched with what was recorded.

      cases = AshDecisions.Replay.recorded(Definition, Evaluation, "risk", actor: a, tenant: t)
      %{counts: counts, cases: cases} = AshDecisions.Replay.run(candidate, cases)

  ## A replay is a trial

  Like `AshDecisions.Trial`, a replay is a question about the model, not a decision about a
  case. Every evaluation runs with `record: false`, so it writes no `Evaluation` row. Rows and
  versions are read as the caller's `:actor` in the caller's `:tenant`, through the host's own
  read policies and **without** the context flag `AshDecisions.Scope.engine/2` sets, so
  someone who may not read a decision's evaluations replays nothing.

  ## The baseline control

  An `Evaluation` row records its inputs as JSON (`AshDecisions.Recorded`), which loses their
  types, and the engine may have been handed either typed values or strings. So before a case
  is compared with the candidate, it is re-run against the version it was recorded under. Only
  when that reproduces the recorded answer and matched rules does the case count; the reading
  of its inputs that reproduced it is the one the candidate is given. A case that does not
  reproduce is reported as `:unreproducible`, never compared: its inputs did not survive the
  record, or the decision depends on something other than its inputs (the clock, an engine
  that has changed since). That makes every `:changed` the candidate's doing.

  ## Outcomes

  Each case gets one of `outcomes/0`:

    * `:unchanged`: the same answer from the same rules (or a failure, again);
    * `:rules_changed`: the same answer, from different rules;
    * `:changed`: a different answer;
    * `:now_fails`: answered before, fails under the candidate;
    * `:now_answers`: failed before, answers under the candidate;
    * `:unreproducible`: the recorded answer could not be reproduced (see above);
    * `:skipped`: the candidate no longer has the decision the case was recorded for.

  ## Cases without a record

  A path that evaluates with `record: false` (a read model computed per request) leaves
  nothing to replay. `compare/4` takes input sets the host builds itself and compares a
  baseline version with the candidate over them, with the same outcomes and result shape.

  ## Result

  Plain maps, with no struct, so a host can render or store them without depending on a type
  from this package:

      %{
        counts: %{unchanged: 41, changed: 2, ...},   # every outcome, zero-filled
        cases: [
          %{
            id: "…",                    # the Evaluation id, or the input set's index
            version: 3,                 # the version the case was recorded under
            recorded_at: ~U[…],         # nil for compare/4
            decision: "Tier",
            outcome: :changed,
            inputs: %{"amount" => "120"},  # as recorded
            missing_inputs: ["region"], # inputs the candidate declares that the case lacks
            before: %{answer: %{"value" => "high"}, rules: ["rule_high"], error: nil},
            after: %{answer: %{"value" => "medium"}, rules: ["rule_mid"], error: nil}
          }
        ]
      }

  `answer` is the output as `AshDecisions.Recorded.encode/1` writes it, so it compares and
  renders the same way as the recorded row.
  """

  alias AshDecisions.Evaluator
  alias AshDecisions.Recorded
  alias AshDecisions.Trial

  @default_limit 200
  @max_limit 1000

  @typedoc "One replayed case's outcome."
  @type outcome ::
          :unchanged
          | :rules_changed
          | :changed
          | :now_fails
          | :now_answers
          | :unreproducible
          | :skipped

  @typedoc "One evaluation's answer, as compared."
  @type answer :: %{answer: term(), rules: [String.t()], error: String.t() | nil}

  @typedoc "A case to replay: a recorded evaluation and the version it was recorded under."
  @type recorded_case :: %{
          id: String.t(),
          definition: struct(),
          decision: String.t() | nil,
          inputs: map(),
          recorded: answer(),
          recorded_at: DateTime.t() | nil
        }

  @doc """
  The outcomes in the order a reader should see them, each with an English label. A host
  translates the labels in its own catalogue.
  """
  @spec outcomes() :: [{outcome(), String.t()}]
  def outcomes do
    [
      changed: "Changed",
      now_fails: "Now fails",
      now_answers: "Now answers",
      rules_changed: "Same answer, different rules",
      unchanged: "Unchanged",
      unreproducible: "Could not be reproduced",
      skipped: "Skipped"
    ]
  end

  @doc """
  The recorded evaluations of decision `key`, newest first, as cases for `run/3`.

  `definition` and `evaluation` are the host's resources. `opts`:

    * `:actor`, `:tenant`: who is asking. Both resources are read through their read
      policies as this actor, without the engine bypass.
    * `:limit`: how many evaluations, default #{@default_limit}, at most #{@max_limit}.

  Only evaluations of versions the actor may read are returned. An empty list means there is
  nothing the actor may replay; a missing key, another tenant's key and a refused read are
  indistinguishable by design.
  """
  @spec recorded(module(), module(), String.t(), keyword()) :: [recorded_case()]
  def recorded(definition, evaluation, key, opts) when is_binary(key) do
    versions = Map.new(Trial.versions(definition, key, opts), &{&1.id, &1})
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)

    if versions == %{} do
      []
    else
      evaluation
      |> Ash.Query.for_read(:read, %{},
        actor: Keyword.get(opts, :actor),
        tenant: Keyword.get(opts, :tenant)
      )
      # By `definition_id`, which is indexed, rather than the denormalised key, which is not.
      |> Ash.Query.do_filter(definition_id: [in: Map.keys(versions)])
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit)
      |> Ash.read()
      |> case do
        {:ok, rows} -> Enum.map(rows, &recorded_case(&1, Map.fetch!(versions, &1.definition_id)))
        {:error, %Ash.Error.Forbidden{}} -> []
        {:error, error} -> raise error
      end
    end
  end

  defp recorded_case(row, definition) do
    %{
      id: row.id,
      definition: definition,
      decision: row.decision_id,
      inputs: row.inputs || %{},
      recorded: %{
        answer: row.outputs,
        rules: row.matched_rule_ids || [],
        error: row.error && to_string(row.error["reason"] || "error")
      },
      recorded_at: row.inserted_at
    }
  end

  @doc """
  Replays `cases` (from `recorded/4`) against `candidate`, a definition struct.

  `opts` takes `:timeout`, passed to each evaluation. See the moduledoc for the result.
  """
  @spec run(struct(), [recorded_case()], keyword()) :: %{counts: map(), cases: [map()]}
  def run(candidate, cases, opts \\ []) when is_list(cases) do
    names = Trial.decisions(candidate)
    declared = candidate |> Trial.inputs() |> Enum.map(& &1.name)

    cases
    |> Enum.map(&replay_case(&1, candidate, names, declared, opts))
    |> summarise()
  end

  defp replay_case(c, candidate, names, declared, opts) do
    readings = Recorded.readings(c.inputs, Trial.inputs(c.definition))

    attempts =
      Enum.map(readings, fn reading -> {reading, evaluate(c.definition, reading, c.decision, opts)} end)

    base = %{
      id: c.id,
      version: c.definition.version,
      recorded_at: c.recorded_at,
      decision: c.decision,
      inputs: c.inputs,
      missing_inputs: Enum.reject(declared, &Map.has_key?(c.inputs, &1)),
      before: c.recorded
    }

    case Enum.find(attempts, fn {_reading, answer} -> reproduces?(answer, c.recorded) end) do
      nil ->
        {_reading, first} = List.first(attempts)
        Map.merge(base, %{outcome: :unreproducible, after: first})

      {reading, _baseline} ->
        if decision_gone?(c.decision, names) do
          Map.merge(base, %{outcome: :skipped, after: nil})
        else
          answer = evaluate(candidate, reading, c.decision, opts)
          Map.merge(base, %{outcome: classify(c.recorded, answer), after: answer})
        end
    end
  end

  @doc """
  Compares `baseline` with `candidate`, two definition structs, over `input_sets`: maps of
  engine values the host builds itself, for a decision that records nothing.

  `opts` takes `:decision` (the decision name, when the documents have more than one) and
  `:timeout`. Each case's `id` is its index in `input_sets`, and `version` the baseline's.
  """
  @spec compare(struct(), struct(), [map()], keyword()) :: %{counts: map(), cases: [map()]}
  def compare(baseline, candidate, input_sets, opts \\ []) when is_list(input_sets) do
    decision = Keyword.get(opts, :decision)
    names = Trial.decisions(candidate)
    declared = candidate |> Trial.inputs() |> Enum.map(& &1.name)

    input_sets
    |> Enum.with_index()
    |> Enum.map(fn {inputs, index} ->
      before = evaluate(baseline, inputs, decision, opts)
      encoded = Recorded.encode(inputs)

      base = %{
        id: index,
        version: baseline.version,
        recorded_at: nil,
        decision: decision,
        inputs: encoded,
        missing_inputs: Enum.reject(declared, &Map.has_key?(encoded, &1)),
        before: before
      }

      if decision_gone?(decision, names) do
        Map.merge(base, %{outcome: :skipped, after: nil})
      else
        answer = evaluate(candidate, inputs, decision, opts)
        Map.merge(base, %{outcome: classify(before, answer), after: answer})
      end
    end)
    |> summarise()
  end

  defp evaluate(definition, inputs, decision, opts) do
    eval_opts =
      [record: false]
      |> put_if(:decision, decision)
      |> put_if(:timeout, Keyword.get(opts, :timeout))

    case Evaluator.evaluate(definition, inputs, eval_opts) do
      {:ok, result} ->
        %{
          answer: if(is_nil(result.outputs), do: nil, else: Recorded.encode(%{"value" => result.outputs})),
          rules: result.matched_rule_ids,
          error: nil
        }

      {:error, reason} ->
        %{answer: nil, rules: [], error: inspect(reason, limit: 5)}
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  # A failure reproduces a failure, whatever its wording; an answer reproduces an answer only
  # with the same value from the same rules.
  defp reproduces?(%{error: e}, %{error: r}) when not is_nil(e) and not is_nil(r), do: true
  defp reproduces?(%{error: nil} = a, %{error: nil} = r), do: same?(a, r) and a.rules == r.rules
  defp reproduces?(_answer, _recorded), do: false

  defp classify(%{error: b}, %{error: a}) when not is_nil(b) and not is_nil(a), do: :unchanged
  defp classify(%{error: nil}, %{error: a}) when not is_nil(a), do: :now_fails
  defp classify(%{error: b}, %{error: nil}) when not is_nil(b), do: :now_answers

  defp classify(before, answer) do
    cond do
      not same?(before, answer) -> :changed
      before.rules != answer.rules -> :rules_changed
      true -> :unchanged
    end
  end

  defp same?(%{answer: a}, %{answer: b}), do: a == b

  # A case recorded for a decision the candidate no longer has (renamed or removed) cannot be
  # put to it. A case that named no decision is put to the candidate as it is.
  defp decision_gone?(nil, _names), do: false
  defp decision_gone?(_decision, []), do: false
  defp decision_gone?(decision, names), do: decision not in names

  defp summarise(cases) do
    zero = Map.new(outcomes(), fn {outcome, _label} -> {outcome, 0} end)
    %{counts: Enum.reduce(cases, zero, &Map.update!(&2, &1.outcome, fn n -> n + 1 end)), cases: cases}
  end
end

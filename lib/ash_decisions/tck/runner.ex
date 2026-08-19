defmodule AshDecisions.Tck.Runner do
  @moduledoc """
  Runs the vendored DMN TCK corpus through the decision engine and reports what happened.

  ## What the outcomes mean, and why they are not all "failed"

  A conformance number is only useful if it distinguishes *the engine got the wrong answer*
  from *we never asked*. Four outcomes:

    * `:passed` — the engine's result matched the expectation, including the ~40% of the
      corpus that expects the engine to fail.
    * `:failed` — the engine answered, and answered wrong. This is the number that matters.
    * `:model_error` — the model would not load or validate, so no result node in it was
      ever evaluated. A construct we do not support lands here, not in `:failed`.
    * `:harness_error` — *this* code could not read the expectation file. Ours to fix, and
      counted separately so it can never be mistaken for an engine result.

  Reporting `:failed` and `:model_error` as one number is the standard way conformance
  claims become misleading, in both directions.
  """

  alias AshDecisions.Tck.{Case, Value}

  @levels ~w(compliance-level-2 compliance-level-3)

  @type outcome :: :passed | :failed | :model_error | :harness_error
  @type result :: %{
          level: String.t(),
          group: String.t(),
          case_id: String.t(),
          decision: String.t(),
          outcome: outcome(),
          detail: String.t() | nil
        }

  @doc "The vendored corpus root."
  @spec corpus_dir() :: Path.t()
  def corpus_dir, do: :code.priv_dir(:ash_decisions) |> Path.join("tck")

  @doc "Every expectation file in the corpus, as `{path, group, level}`."
  @spec case_files(keyword()) :: [{Path.t(), String.t(), String.t()}]
  def case_files(opts \\ []) do
    levels = Keyword.get(opts, :levels, @levels)

    for level <- levels,
        group_dir <- Path.wildcard(Path.join([corpus_dir(), level, "*"])),
        File.dir?(group_dir),
        file <- Path.wildcard(Path.join(group_dir, "*-test-*.xml")) do
      {file, Path.basename(group_dir), level}
    end
    |> Enum.sort()
  end

  @doc """
  Runs the corpus. Returns `{results, summary}`.

  Models are loaded once per expectation file rather than once per case; a group like
  `0100-feel-constants` has hundreds of cases against one model and re-parsing it for each
  turns a 30-second run into a 10-minute one.
  """
  @spec run(keyword()) :: {[result()], map()}
  def run(opts \\ []) do
    downgrade? = Keyword.get(opts, :downgrade, false)

    results =
      opts
      |> case_files()
      |> Task.async_stream(
        fn entry ->
          # Each case file runs in its own task, so the flag has to be set inside it.
          Process.put(:ash_decisions_tck_downgrade, downgrade?)
          run_file(entry)
        end,
        timeout: :infinity,
        ordered: true
      )
      |> Enum.flat_map(fn {:ok, rs} -> rs end)

    {results, summarize(results)}
  end

  defp run_file({file, group, level}) do
    case Case.load_file(file, group, level) do
      {:error, reason} ->
        [result(level, group, "-", "-", :harness_error, reason)]

      {:ok, []} ->
        []

      {:ok, [first | _] = cases} ->
        case load_model(first.model_path) do
          {:ok, model} -> Enum.flat_map(cases, &run_case(&1, model))
          {:error, reason} -> Enum.flat_map(cases, &model_error(&1, reason))
        end
    end
  end

  # `load_file/1` rather than reading the file and calling `load_xml/1`: several groups
  # (`0086-import`, `0089-nested-inputdata-imports`) import sibling documents, and only the
  # file-based loader resolves those relative to the model's own directory.
  defp load_model(path) do
    # Read and normalize rather than `load_file/1`, so the corpus exercises the same path a
    # published definition takes. `--downgrade` additionally rewrites each model to DMN 1.3
    # first, which is how the namespace normalization in `AshDecisions.Dmn.Profile` is checked
    # against real models rather than against an argument about the specification.
    with {:ok, xml} <- File.read(path),
         xml = maybe_downgrade(xml),
         {:ok, model} <- xml |> AshDecisions.Dmn.Profile.normalize() |> Boxic.DMN.load_xml() do
      # Validation failures are reported as model errors rather than swallowed: a model the
      # engine considers invalid cannot produce a meaningful result, and pretending
      # otherwise would score the corpus against an engine running in an undefined state.
      case Boxic.DMN.validate(model) do
        :ok -> {:ok, model}
        {:error, errors} -> {:error, "invalid model: #{inspect(errors, limit: 3)}"}
      end
    else
      {:error, reason} -> {:error, "load failed: #{inspect(reason, limit: 3)}"}
    end
  rescue
    e -> {:error, "load raised: #{Exception.message(e)}"}
  end

  # Rewrites a model to the DMN 1.3 namespaces, so a run can prove that a 1.3 document -- which
  # is what `dmn-js` produces -- reaches the same answers as the 1.5 original.
  defp maybe_downgrade(xml) do
    if Process.get(:ash_decisions_tck_downgrade) do
      xml
      |> String.replace(
        "https://www.omg.org/spec/DMN/20230324/MODEL/",
        "https://www.omg.org/spec/DMN/20191111/MODEL/"
      )
      |> String.replace(
        "https://www.omg.org/spec/DMN/20230324/FEEL/",
        "https://www.omg.org/spec/DMN/20191111/FEEL/"
      )
    else
      xml
    end
  end

  defp model_error(%Case{} = c, reason) do
    Enum.map(c.results, &result(c.level, c.group, c.id, &1.name, :model_error, reason))
  end

  defp run_case(%Case{} = c, model) do
    Enum.map(c.results, fn expectation ->
      actual = evaluate(model, c, expectation.name)
      compare(c, expectation, actual)
    end)
  end

  defp evaluate(model, %Case{type: "decisionService", invocable: name} = c, _decision)
       when is_binary(name) do
    Boxic.DMN.evaluate_service(model, name, c.inputs)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp evaluate(model, %Case{} = c, decision) do
    Boxic.DMN.evaluate(model, decision, c.inputs)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  # See `AshDecisions.Tck.Case` on why `errorResult="true"` is satisfied by `null`: FEEL has
  # no exceptions, and the corpus states the expectation as nil alongside the flag.
  defp compare(c, %{expects_error?: true} = e, actual) do
    case actual do
      {:error, _} ->
        result(c.level, c.group, c.id, e.name, :passed, nil)

      {:ok, nil} ->
        result(c.level, c.group, c.id, e.name, :passed, nil)

      {:ok, value} ->
        result(
          c.level,
          c.group,
          c.id,
          e.name,
          :failed,
          "expected null or an error, got #{trunc_inspect(value)}"
        )
    end
  end

  defp compare(c, e, actual) do
    case actual do
      {:ok, value} ->
        if Value.matches?(e.expected, value) do
          result(c.level, c.group, c.id, e.name, :passed, nil)
        else
          result(
            c.level,
            c.group,
            c.id,
            e.name,
            :failed,
            "expected #{trunc_inspect(e.expected)}, got #{trunc_inspect(value)}"
          )
        end

      {:error, reason} ->
        result(c.level, c.group, c.id, e.name, :failed, "engine error: #{trunc_inspect(reason)}")
    end
  end

  defp result(level, group, case_id, decision, outcome, detail) do
    %{
      level: level,
      group: group,
      case_id: case_id,
      decision: decision,
      outcome: outcome,
      detail: detail
    }
  end

  defp trunc_inspect(term), do: inspect(term, limit: 5, printable_limit: 120)

  @doc "Counts by outcome, overall and per compliance level."
  @spec summarize([result()]) :: map()
  def summarize(results) do
    %{
      total: length(results),
      by_outcome: tally(results, & &1.outcome),
      by_level:
        results
        |> Enum.group_by(& &1.level)
        |> Map.new(fn {level, rs} ->
          {level, %{total: length(rs), by_outcome: tally(rs, & &1.outcome)}}
        end)
    }
  end

  defp tally(results, fun), do: results |> Enum.frequencies_by(fun)
end

defmodule Mix.Tasks.AshDecisions.Tck do
  @shortdoc "Run the vendored DMN TCK corpus and report conformance"

  @moduledoc """
  Runs the vendored DMN TCK corpus through the decision engine and prints the score.

      mix ash_decisions.tck
      mix ash_decisions.tck --level compliance-level-2
      mix ash_decisions.tck --failures
      mix ash_decisions.tck --json artifacts/tck.json

  ## Options

    * `--level LEVEL` — restrict to one compliance level; repeatable.
    * `--failures` — list every failing and model-error case with its detail.
    * `--json PATH` — write the full result set as JSON.
    * `--downgrade` — rewrite every model to the DMN 1.3 namespaces before loading. The corpus
      ships as DMN 1.5 and the engine loads only 1.5, but `dmn-js` writes 1.3 — so this run is
      what proves `AshDecisions.Dmn.Profile` brings a designer document forward without
      changing a single answer. Identical numbers with and without it is the whole claim.

  ## The gate

  The task fails when either half of the contract is broken:

    * a group **fails and is not** in `AshDecisions.Tck.ExpectedFailures` — a regression, or a
      newly vendored corpus exposing something; or
    * a group is **listed there and passes** — the entry is stale and must be deleted.

  The second is what stops the list becoming a place failures go to be forgotten, and it is
  why the list can only ever shrink.
  """

  use Mix.Task

  alias AshDecisions.Tck.ExpectedFailures
  alias AshDecisions.Tck.Runner

  @switches [level: :keep, failures: :boolean, json: :string, downgrade: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    levels = Keyword.get_values(opts, :level)
    run_opts = if levels == [], do: [], else: [levels: levels]
    run_opts = Keyword.put(run_opts, :downgrade, opts[:downgrade] || false)

    {results, summary} = Runner.run(run_opts)

    report(summary)
    if opts[:failures], do: failures(results)
    if opts[:json], do: write_json(opts[:json], results, summary)

    gate(results, summary)
  end

  defp gate(results, summary) do
    harness = Map.get(summary.by_outcome, :harness_error, 0)

    bad = for r <- results, r.outcome in [:failed, :model_error], is_nil(expected(r)), do: r
    drifted = drifted_counts(results)

    Mix.shell().info(
      "\nexpected failures: #{length(ExpectedFailures.groups())} groups, " <>
        "#{ExpectedFailures.total_expected()} result nodes"
    )

    cond do
      harness > 0 ->
        Mix.raise("DMN TCK: #{harness} harness errors — this runner could not read the corpus")

      bad != [] ->
        Mix.raise("""
        DMN TCK: #{length(bad)} unexpected failures.

        #{bad |> Enum.map(&"  #{&1.level}/#{&1.group}/#{&1.case_id} #{&1.decision}: #{&1.detail}") |> Enum.take(15) |> Enum.join("\n")}

        Either fix the cause, or add the group to AshDecisions.Tck.ExpectedFailures with the
        reason it cannot pass and the number of nodes that fail.
        """)

      drifted != [] ->
        Mix.raise("""
        DMN TCK: #{length(drifted)} groups fail a different number of nodes than recorded.

        #{drifted |> Enum.map(fn {level, group, expected, actual} -> "  #{level}/#{group}: recorded #{expected}, measured #{actual}#{verdict(expected, actual)}" end) |> Enum.join("\n")}

        Fewer than recorded is progress: update the count in
        AshDecisions.Tck.ExpectedFailures, or delete the entry if it reached zero.
        More than recorded is a regression hiding behind an excuse -- the whole reason
        these entries carry a count rather than blanket-excusing the group.
        """)

      true ->
        Mix.shell().info("DMN TCK: clean\n")
    end
  end

  defp expected(r), do: ExpectedFailures.reason(r.level, r.group)

  defp verdict(expected, actual) when actual < expected, do: "  (progress)"
  defp verdict(_expected, _actual), do: "  (REGRESSION)"

  # A listed group whose failing-node count has moved in either direction.
  #
  # This is what makes the excuse specific rather than blanket. Keying on the group alone
  # excused every node in it: measured at the time this was written, 1,206 nodes to excuse 81
  # real failures, with 1,086 of `0100-arithmetic`'s 1,087 riding along.
  defp drifted_counts(results) do
    actual =
      results
      |> Enum.group_by(&{&1.level, &1.group})
      |> Map.new(fn {key, rs} -> {key, Enum.count(rs, &(&1.outcome != :passed))} end)

    for {level, group} <- ExpectedFailures.groups(),
        expected = ExpectedFailures.expected_count(level, group),
        # A listed group the corpus no longer contains is reported by `tck.verify`, not here.
        measured = Map.get(actual, {level, group}),
        not is_nil(measured),
        measured != expected,
        do: {level, group, expected, measured}
  end

  defp report(summary) do
    Mix.shell().info("\nDMN TCK — #{summary.total} result nodes\n")

    summary.by_level
    |> Enum.sort()
    |> Enum.each(fn {level, s} -> line(level, s.total, s.by_outcome) end)

    line("all levels", summary.total, summary.by_outcome)
  end

  defp line(label, total, by_outcome) do
    passed = Map.get(by_outcome, :passed, 0)
    pct = if total > 0, do: Float.round(passed * 100 / total, 2), else: 0.0

    Mix.shell().info(
      String.pad_trailing(label, 22) <>
        "#{String.pad_leading(to_string(passed), 5)}/#{String.pad_trailing(to_string(total), 5)} " <>
        "#{String.pad_leading(:erlang.float_to_binary(pct, decimals: 2), 6)}%   " <>
        "failed #{Map.get(by_outcome, :failed, 0)}  " <>
        "model_error #{Map.get(by_outcome, :model_error, 0)}  " <>
        "harness_error #{Map.get(by_outcome, :harness_error, 0)}"
    )
  end

  defp failures(results) do
    results
    |> Enum.filter(&(&1.outcome in [:failed, :model_error, :harness_error]))
    |> Enum.group_by(& &1.outcome)
    |> Enum.sort()
    |> Enum.each(fn {outcome, rs} ->
      Mix.shell().info("\n## #{outcome} (#{length(rs)})\n")

      rs
      |> Enum.group_by(&{&1.group, &1.detail})
      |> Enum.sort_by(fn {_k, v} -> -length(v) end)
      |> Enum.each(fn {{group, detail}, occurrences} ->
        Mix.shell().info("  #{group} (x#{length(occurrences)}) — #{detail}")
      end)
    end)
  end

  defp write_json(path, results, summary) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{summary: summary, results: results}, pretty: true))
    Mix.shell().info("\nwrote #{path}")
  end
end

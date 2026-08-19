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

  ## The gate

  The task fails when either half of the contract is broken:

    * a group **fails and is not** in `AshDecisions.Tck.ExpectedFailures` — a regression, or a
      newly vendored corpus exposing something; or
    * a group is **listed there and passes** — the entry is stale and must be deleted.

  The second is what stops the list becoming a place failures go to be forgotten, and it is
  why the list can only ever shrink.
  """

  use Mix.Task

  alias AshDecisions.Tck.Runner

  @switches [level: :keep, failures: :boolean, json: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    levels = Keyword.get_values(opts, :level)
    run_opts = if levels == [], do: [], else: [levels: levels]

    {results, summary} = Runner.run(run_opts)

    report(summary)
    if opts[:failures], do: failures(results)
    if opts[:json], do: write_json(opts[:json], results, summary)

    gate(results, summary)
  end

  defp gate(results, summary) do
    harness = Map.get(summary.by_outcome, :harness_error, 0)

    bad = for r <- results, r.outcome in [:failed, :model_error], is_nil(expected(r)), do: r
    stale = stale_entries(results)

    Mix.shell().info(
      "\nexpected failures: #{length(AshDecisions.Tck.ExpectedFailures.groups())} groups listed"
    )

    cond do
      harness > 0 ->
        Mix.raise("DMN TCK: #{harness} harness errors — this runner could not read the corpus")

      bad != [] ->
        Mix.raise("""
        DMN TCK: #{length(bad)} unexpected failures.

        #{bad |> Enum.map(&"  #{&1.level}/#{&1.group}/#{&1.case_id} #{&1.decision}: #{&1.detail}") |> Enum.take(15) |> Enum.join("\n")}

        Either fix the cause, or add the group to AshDecisions.Tck.ExpectedFailures with the
        reason it cannot pass.
        """)

      stale != [] ->
        Mix.raise("""
        DMN TCK: #{length(stale)} groups are listed as expected failures but now pass.

        #{stale |> Enum.map(fn {level, group} -> "  #{level}/#{group}" end) |> Enum.join("\n")}

        Delete them from AshDecisions.Tck.ExpectedFailures — the list may only shrink.
        """)

      true ->
        Mix.shell().info("DMN TCK: clean\n")
    end
  end

  defp expected(r), do: AshDecisions.Tck.ExpectedFailures.reason(r.level, r.group)

  defp stale_entries(results) do
    outcomes =
      Enum.group_by(results, &{&1.level, &1.group}, & &1.outcome)

    for key <- AshDecisions.Tck.ExpectedFailures.groups(),
        seen = Map.get(outcomes, key),
        is_list(seen),
        Enum.all?(seen, &(&1 == :passed)),
        do: key
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

defmodule AshDecisions.Tck.ExpectedFailures do
  @moduledoc """
  The cases we know do not pass, each with the reason it does not.

  ## Why this list exists, and why it can only shrink

  A conformance suite that merely prints a percentage is a report. This list makes it a gate:
  a result that fails and is **not** listed here fails the build, and a result that passes
  while still listed here *also* fails the build. The second half is the important one — it
  means the list cannot quietly accumulate entries that stopped being true, and shrinking it
  is the visible measure of progress.

  This is the same posture as `.dialyzer_ignore.exs` with `list_unused_filters: true` in
  `ash_enterprise`, and for the same reason.

  ## Each entry carries a count, and the count is the whole point

  The first version of this list keyed on `{level, group}` alone, which excused *every* result
  node in a listed group. Measured rather than assumed: that blanket covered **1,206 nodes to
  excuse 81 real failures**. `0100-arithmetic` is the extreme case — 1,087 nodes, exactly one of
  which fails — so 1,086 passing assertions were silently exempt from the gate, and a genuine
  regression in any of them would not have failed the build. A conformance gate with a
  thousand-node hole in it is a report wearing a gate's clothes.

  So an entry is `{expected_failing_nodes, reason}`, and a listed group whose failing count
  moves in **either** direction fails the build. Fewer failures than recorded means progress
  that must be written down; more means a regression hiding behind an excuse.

  ## What is here, and what it says about the engine

  Nothing in this list is a wrong answer to a question we asked correctly. The entries fall
  into four kinds:

    * **Deliberately unsupported** — external Java functions. A DMN document that reaches out
      to `java.lang.Math` is arbitrary code execution driven by a tenant-authored model. We
      would refuse it even if the engine supported it, so this is a permanent entry rather
      than a gap.
    * **Engine validator stricter than the spec** — models whose elements omit an optional
      `id`, or whose imports omit a `locationURI`. Reportable upstream; not a correctness
      problem in evaluation.
    * **Last-digit arithmetic** — loan-amortisation groups that exercise exponentiation and
      disagree with the corpus in the final one or two digits of a fifteen-significant-digit
      expectation.
    * **One semantic difference** — a decision service with several output decisions returns
      the whole context rather than a per-decision result.
  """

  # The loan-amortisation groups all disagree the same way, so they share one reason.
  @arithmetic "last-digit disagreement in exponentiation"

  # `{failing result nodes, reason}`. The counts are measured, not estimated: run
  # `mix ash_decisions.tck --failures` to see the nodes behind each one.
  @entries %{
    {"compliance-level-3", "0076-feel-external-java"} =>
      {14, "external Java functions: deliberately unsupported, and refused on safety grounds"},
    {"compliance-level-3", "1111-feel-matches-function"} =>
      {40, "engine validator requires an `id` the DMN schema makes optional (upstream)"},
    {"compliance-level-3", "0087-chapter-11-example"} =>
      {9, "engine validator rejects a decision carrying no logic (upstream)"},
    {"compliance-level-3", "0088-no-decision-logic"} =>
      {1,
       "engine validator rejects a decision carrying no logic -- which is what this group tests (upstream)"},
    {"compliance-level-3", "0086-import"} =>
      {2,
       "engine requires `locationURI` on an import; the corpus resolves by namespace (upstream)"},
    {"compliance-level-3", "0089-nested-inputdata-imports"} =>
      {1,
       "engine requires `locationURI` on an import; the corpus resolves by namespace (upstream)"},
    {"compliance-level-3", "0085-decision-services"} =>
      {2,
       "a multi-output decision service returns the whole context rather than one decision's result"},
    {"compliance-level-2", "0008-LX-arithmetic"} => {2, @arithmetic},
    {"compliance-level-2", "0009-invocation-arithmetic"} => {2, @arithmetic},
    {"compliance-level-3", "0005-literal-invocation"} => {2, @arithmetic},
    {"compliance-level-3", "0003-iteration"} => {1, @arithmetic},
    {"compliance-level-3", "0004-lending"} => {1, @arithmetic},
    {"compliance-level-3", "0014-loan-comparison"} => {1, @arithmetic},
    {"compliance-level-3", "0040-singlenestedcontext"} => {1, @arithmetic},
    {"compliance-level-3", "0041-multiple-nestedcontext"} => {1, @arithmetic},
    {"compliance-level-3", "0100-arithmetic"} => {1, @arithmetic}
  }

  @doc "The reason this group is expected to fail, or nil if it is expected to pass."
  @spec reason(String.t(), String.t()) :: String.t() | nil
  def reason(level, group) do
    case Map.get(@entries, {level, group}) do
      {_count, reason} -> reason
      nil -> nil
    end
  end

  @doc """
  How many result nodes in this group are expected to fail, or nil if none are.

  The gate compares this to the measured count and fails on any difference, in
  either direction. See the moduledoc for why the count and not merely the group.
  """
  @spec expected_count(String.t(), String.t()) :: non_neg_integer() | nil
  def expected_count(level, group) do
    case Map.get(@entries, {level, group}) do
      {count, _reason} -> count
      nil -> nil
    end
  end

  @doc "Every listed `{level, group}`."
  @spec groups() :: [{String.t(), String.t()}]
  def groups, do: Map.keys(@entries)

  @doc "The total number of result nodes this list excuses."
  @spec total_expected() :: non_neg_integer()
  def total_expected, do: @entries |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.sum()
end

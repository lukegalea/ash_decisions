defmodule AshDecisions.Verifier do
  @moduledoc """
  Publish-time verification over a compiled decision graph.

  The compiler answers "does this document mean anything?"; verification answers
  "is what it means sound?" — can two rules of a `UNIQUE` table both fire, is
  there input the table answers `null` to, which cells could not be decided at
  all. It runs after compilation, over the compiled `graph` rather than the XML
  (the graph already holds hit policies, clause `type_ref`s and the source text
  of every entry, which is the whole input), and its output has a different
  lifecycle from `errors`: `errors` non-empty is a valid draft state that stops a
  publish; findings and obligations are stored beside it as `verification`, and
  only `severity: :error` findings block the publish
  (`AshDecisions.Resources.Definition.VerificationClean`).

  Two kinds of answer, and the second is the one that earns its keep:

    * `findings` — what was **proved**: an overlap with a witness region, a gap
      with a witness input, a rule that can never fire. See
      `AshDecisions.Verification.Finding`.
    * `obligations` — what could **not** be decided: an opaque cell, an untyped
      column, a table past the region cap, a `COLLECT` policy under which overlap
      is legal. An undecidable table is never reported as clean; it is also
      never blocked, because refusing to publish over the verifier's own
      incompleteness would make the verifier the thing people route around. See
      `AshDecisions.Verification.Obligation`.

  `verifier_version` travels with the result for the same reason
  `graph.feel_engine.version` does: a definition published under an older
  verifier was proved less, and a consumer holding the row needs to know that
  without re-deriving it.
  """

  alias AshDecisions.Verification.DecisionTable
  alias AshDecisions.Verification.Finding
  alias AshDecisions.Verification.Obligation

  @version "0.1.0"

  @type result :: %{
          required(:findings) => [Finding.t()],
          required(:obligations) => [Obligation.t()],
          required(:verified_at) => DateTime.t(),
          required(:verifier_version) => String.t()
        }

  @doc """
  Verifies every decision table in the compiled graph.

  Decisions are analysed in document order, so findings and obligations address
  the document the way an author reads it. A graph with no decision tables —
  every decision a literal expression — verifies to nothing found and nothing
  owed: there is no input space to reason about, and the compiler already proved
  every expression parses.
  """
  @spec verify(map()) :: result()
  def verify(graph) when is_map(graph) do
    decisions = graph["decisions"] || %{}
    order = graph["decision_order"] || Map.keys(decisions)

    {findings, obligations} =
      order
      |> Enum.map(&decisions[&1])
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce({[], []}, fn decision, {findings, obligations} ->
        {more_findings, more_obligations} = DecisionTable.analyze(decision)
        {findings ++ more_findings, obligations ++ more_obligations}
      end)

    %{
      findings: findings,
      obligations: obligations,
      verified_at: DateTime.utc_now(),
      verifier_version: @version
    }
  end

  @doc """
  Projects a verification result into the JSON-safe map stored in a definition's
  `verification` attribute.

  The stored form is what survives a jsonb round trip: string keys, string
  atoms, a rendered timestamp. `VerificationClean` reads this shape when it
  decides whether a publish may proceed.
  """
  @spec to_storage(result()) :: map()
  def to_storage(result) do
    %{
      "findings" => Enum.map(result.findings, &Finding.to_map/1),
      "obligations" => Enum.map(result.obligations, &Obligation.to_map/1),
      "verified_at" => DateTime.to_iso8601(result.verified_at),
      "verifier_version" => result.verifier_version
    }
  end
end

defmodule AshDecisions.Dmn.Profile do
  @moduledoc """
  Brings a DMN document to the specification revision the engine executes.

  ## The problem this exists for

  Two halves of the toolchain disagree about which DMN they speak, and neither is wrong:

    * **`dmn-js`** — the bpmn.io modeller, and the only serious browser DMN editor — has
      emitted **DMN 1.3** since its 8.0.0 release and still does at 17.x.
    * **`boxic_dmn`** — the engine — loads **DMN 1.5** and refuses anything else outright,
      with `:dmn_version_mismatch`.

  So a document drawn in the designer would be rejected by the engine that has to run it. That
  is not a preference to be argued about; it is an integration that does not work.

  ## What this does, and what it refuses to do

  It rewrites the **namespace URIs** — the `MODEL` and `FEEL` namespaces — from any DMN
  revision the corpus and the tooling actually produce (1.1 through 1.4) to 1.5. Nothing else.
  No element is added, removed, renamed or reordered.

  That narrowness is the whole safety argument. For the subset this package executes —
  decision tables, literal expressions, information requirements and input data — the
  structure is identical across those revisions; what 1.4 and 1.5 added, they added *beside*
  it. And everything outside that subset is already refused by `AshDecisions.Compiler` with the
  element id, before any of this runs. A construct whose meaning changed between revisions is
  therefore a construct we do not execute.

  ## The normalized document is never stored

  `Definition.xml` keeps exactly what the author submitted, byte for byte, because
  `content_hash` is what says a snapshot and a document belong together and an artifact the
  store quietly rewrote is an artifact whose hash identifies something nobody sent.
  Normalization happens on the way *into the engine* and nowhere else, so the document you can
  export is the document you drew.

  ## How the safety claim was checked

  Not by reading the specification diffs. The vendored DMN TCK corpus is entirely DMN 1.5, so
  it was downgraded — every model rewritten to the 1.3 namespaces — and the conformance suite
  re-run through this module. Identical results mean the rewrite is sound for precisely the
  constructs the corpus exercises, which is a stronger statement than any argument from the
  specification text.
  """

  # Every DMN revision's MODEL namespace, and the FEEL namespace that travels with it. Both
  # `http` and `https` spellings appear in the wild: the OMG published earlier revisions under
  # `http` and later ones under `https`, and exporters are inconsistent about it.
  @model_namespaces [
    "http://www.omg.org/spec/DMN/20151101/MODEL/",
    "https://www.omg.org/spec/DMN/20151101/MODEL/",
    "http://www.omg.org/spec/DMN/20180521/MODEL/",
    "https://www.omg.org/spec/DMN/20180521/MODEL/",
    "http://www.omg.org/spec/DMN/20191111/MODEL/",
    "https://www.omg.org/spec/DMN/20191111/MODEL/",
    "http://www.omg.org/spec/DMN/20211108/MODEL/",
    "https://www.omg.org/spec/DMN/20211108/MODEL/"
  ]

  @feel_namespaces [
    "http://www.omg.org/spec/DMN/20151101/FEEL/",
    "https://www.omg.org/spec/DMN/20151101/FEEL/",
    "http://www.omg.org/spec/DMN/20180521/FEEL/",
    "https://www.omg.org/spec/DMN/20180521/FEEL/",
    "http://www.omg.org/spec/DMN/20191111/FEEL/",
    "https://www.omg.org/spec/DMN/20191111/FEEL/",
    "http://www.omg.org/spec/DMN/20211108/FEEL/",
    "https://www.omg.org/spec/DMN/20211108/FEEL/"
  ]

  @executable_model "https://www.omg.org/spec/DMN/20230324/MODEL/"
  @executable_feel "https://www.omg.org/spec/DMN/20230324/FEEL/"

  # DMN 1.3, which is the latest revision dmn-js's moddle understands. See `to_editable/1`.
  @editable_model "https://www.omg.org/spec/DMN/20191111/MODEL/"
  @editable_feel "https://www.omg.org/spec/DMN/20191111/FEEL/"

  @doc "The revision the engine executes, as a MODEL namespace URI."
  @spec executable_namespace() :: String.t()
  def executable_namespace, do: @executable_model

  @doc "The DMN revisions this module knows how to bring forward, as MODEL namespace URIs."
  @spec known_namespaces() :: [String.t()]
  def known_namespaces, do: @model_namespaces

  @doc """
  Whether `xml` already declares the executable revision.

  Useful for saying "this was normalized" in a diagnostic without doing the work twice.
  """
  @spec executable?(String.t()) :: boolean()
  def executable?(xml) when is_binary(xml), do: String.contains?(xml, @executable_model)

  @doc """
  Rewrites `xml`'s DMN namespaces to the executable revision.

  A document that already declares it is returned unchanged. A document declaring no DMN
  namespace at all is also returned unchanged — it is not ours to fix, and the engine's own
  error is clearer than anything this module could invent.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(xml) when is_binary(xml) do
    if executable?(xml) do
      xml
    else
      xml
      |> replace_all(@model_namespaces, @executable_model)
      |> replace_all(@feel_namespaces, @executable_feel)
    end
  end

  @doc """
  Rewrites `xml`'s DMN namespaces to the revision **dmn-js** can open.

  The mirror of `normalize/1`, and it exists because the incompatibility runs both ways. The
  engine refuses anything that is not DMN 1.5; dmn-js's moddle knows nothing later than 1.3 and
  reports `failed to parse document as <dmn:Definitions>` on a 1.5 document — a message that
  names the element and not the cause.

  So a baseline written in 1.5 for the engine is a baseline the editor cannot open, which is how
  this was found: the decision editor rendered its own error panel over an empty canvas, on a
  document that compiled and evaluated perfectly.

  Neither direction touches storage. A definition holds whatever its author submitted, byte for
  byte, and each consumer is handed the dialect it understands — `normalize/1` on the way to the
  engine, this on the way to the editor. Rewriting on save instead would make the stored
  document a function of which tool last opened it.

  ## Why it is safe in this direction as well as the other

  The rewrite is namespace-only. Between 1.3 and 1.5 the DMN *schema* gained elements, but every
  construct this package compiles — `decisionTable`, `literalExpression`, `informationRequirement`,
  and DMNDI — is spelled identically in both, so a document restricted to that subset means the
  same thing under either namespace. A document using something 1.5 added would lose it here, and
  that document is one the compiler already refuses by element id.
  """
  @spec to_editable(String.t()) :: String.t()
  def to_editable(xml) when is_binary(xml) do
    xml
    |> replace_all([@executable_model | @model_namespaces], @editable_model)
    |> replace_all([@executable_feel | @feel_namespaces], @editable_feel)
  end

  @doc "The revision the dmn-js editor can open, as a MODEL namespace URI."
  @spec editable_namespace() :: String.t()
  def editable_namespace, do: @editable_model

  defp replace_all(xml, from_list, to) do
    Enum.reduce(from_list, xml, fn from, acc -> String.replace(acc, from, to) end)
  end
end

# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.BandTable do
  @moduledoc """
  Lands a generated evidence band table as policy data.

  A calibration pipeline — ash_judgments' `Calibration.ProposalDmn` renderer
  is the producing example — finishes with a two-band DMN document: the score
  gates on the earned threshold, `admit` above it, `review` below it, and
  **no default rule**, so a score that is absent or not a number matches no
  row and the empty match is a refusal, not a result. That document is this
  module's whole input. This package generates nothing and knows nothing
  about calibration: the band table arrives finished, and it arrives as DMN —
  which is the only artifact a decision ever is here. There is deliberately
  no band-table resource and no rule-row import: either would be a second
  copy of the rules, and the moment one exists someone edits a row and the
  document disagrees.

  ## The import contract

  `import_document/2` accepts a document only when it *is* a band table:

    * it compiles — `AshDecisions.Compiler.compile/1` runs first, with every
      refusal and hostile-input bound that implies;
    * exactly one decision, whose logic is a decision table;
    * hit policy `UNIQUE` — one band per case, and an answer that does not
      depend on where a rule sits in the document;
    * an output named `band`, of type `string` — the band vocabulary is
      strings, and a number that happens to be called a band is not one;
    * **no default output entry on any output.** The generated table's
      refusal semantics live in this absence: a default entry would absorb
      exactly the malformed-score case that must come back as an empty
      match. A landed band table that quietly answers on garbage is not the
      table the calibration run earned.
    * **the document must be able to answer.** The engine types the decision
      variable against the table's compound output, so a multi-output table
      under a scalar `typeRef` compiles and verifies clean and then
      type-errors on every evaluation. Import refuses it here, naming the
      one-attribute fix, because a band table that cannot decide is not
      policy data — it is a published error waiting for its first call.

  The key and the name are taken from the decision's name — the renderer
  writes the draft definition's key (the family-tagged `bands_<family>`
  naming convention) into it, which is what a host's `publish_verifiers`
  gate keys its calibration evidence off.

  ## The landing

  `land/3` is import plus the ordinary lifecycle: create the draft, then
  publish it — so the compiler, the publish-time verification and every
  configured `AshDecisions.Config.publish_verifiers/0` gate run unchanged.
  Who certifies is the host's business: pass `publish?: false` to stop at
  the draft and let a person run `publish!/1` after looking at it.

  The XML is stored byte-for-byte; `content_hash` binds the published
  snapshot to the document the generator emitted.
  """

  alias AshDecisions.Compiler
  alias AshDecisions.Tck.Xml

  @band_output "band"

  @type attrs :: %{key: String.t(), name: String.t(), xml: String.t()}
  @type import_error :: Compiler.error()

  @doc """
  Validates a band-table document and returns the definition's create attributes.

  Returns `{:ok, %{key:, name:, xml:}}` — the input map for a definition
  resource's `create` action — or `{:error, errors}` in the compiler's
  `%{path:, message:}` shape. The XML is returned verbatim, never rewritten.

  Options:

    * `:name` — override the definition's display name (default: the
      decision's name).
  """
  @spec import_document(String.t(), keyword()) :: {:ok, attrs()} | {:error, [import_error()]}
  def import_document(xml, opts \\ []) when is_binary(xml) do
    with {:ok, graph} <- Compiler.compile(xml),
         {:ok, decision} <- single_decision(graph),
         {:ok, table} <- decision_table(decision),
         :ok <- unique_policy(decision, table),
         {:ok, _band} <- band_output(decision, table),
         :ok <- no_default_entries(decision, table),
         :ok <- evaluable_variable(xml, decision, table) do
      name = decision["name"]

      {:ok, %{key: name, name: Keyword.get(opts, :name) || name, xml: xml}}
    end
  end

  @doc "Like `import_document/2`, raising on failure with the errors formatted."
  @spec import_document!(String.t(), keyword()) :: attrs()
  def import_document!(xml, opts \\ []) do
    case import_document(xml, opts) do
      {:ok, attrs} -> attrs
      {:error, errors} -> raise "not a band table:\n" <> Compiler.format_errors(errors)
    end
  end

  @doc """
  Lands `xml` on `resource` as policy data: import, create the draft, publish.

  `resource` is the host's generated definition resource — the module that
  used `AshDecisions.Resources.Definition`. Every option other than the two
  below is forwarded verbatim to both Ash calls (`actor:`, `tenant:`, …).

  Options:

    * `:name` — override the definition's display name.
    * `:publish?` — publish after creating (default `true`). `false` stops
      at the draft, for hosts whose certification is a person's act.
  """
  @spec land(module(), String.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def land(resource, xml, opts \\ []) when is_atom(resource) do
    import_opts = Keyword.take(opts, [:name])
    call_opts = Keyword.drop(opts, [:name, :publish?])

    with {:ok, attrs} <- import_document(xml, import_opts),
         {:ok, definition} <- resource.create(attrs, call_opts) do
      if Keyword.get(opts, :publish?, true) do
        resource.publish(definition, call_opts)
      else
        {:ok, definition}
      end
    end
  end

  @doc "Like `land/3`, raising on failure."
  @spec land!(module(), String.t(), keyword()) :: struct()
  def land!(resource, xml, opts \\ []) do
    case land(resource, xml, opts) do
      {:ok, definition} -> definition
      {:error, error} -> raise "the band table could not be landed: #{render(error)}"
    end
  end

  # ── the contract, clause by clause ────────────────────────────────────────

  # The renderer emits one decision per document, and a band table *is* one
  # decision: the bands of a second decision would land under a key that
  # names only the first.
  defp single_decision(graph) do
    decisions = Enum.map(graph["decision_order"], &graph["decisions"][&1])

    case decisions do
      [decision] ->
        {:ok, decision}

      many ->
        {:error,
         [
           error(
             "definitions",
             "a band table is one decision; this document declares #{length(many)}"
           )
         ]}
    end
  end

  # The snapshot merges the table's fields into the decision map (the compiler
  # holds one logic per decision), so the "table" here is the decision itself.
  defp decision_table(decision) do
    case decision["logic"] do
      "decisionTable" ->
        {:ok, decision}

      other ->
        {:error,
         [
           error(
             decision["id"],
             "the decision '#{decision["name"]}' is a #{other}, not a decision table; " <>
               "a band table decides by rows"
           )
         ]}
    end
  end

  defp unique_policy(decision, table) do
    policy = table["hit_policy"]

    if policy == "UNIQUE" do
      :ok
    else
      {:error,
       [
         error(
           decision["id"],
           "a band table's hit policy is UNIQUE (got #{policy}): one band per case, " <>
             "and an answer that does not depend on rule order"
         )
       ]}
    end
  end

  defp band_output(decision, table) do
    band = Enum.find(table["outputs"], &(&1["name"] == @band_output))

    cond do
      is_nil(band) ->
        {:error,
         [
           error(
             decision["id"],
             "no output named '#{@band_output}'; a band table's answer is its band"
           )
         ]}

      band["type_ref"] != "string" ->
        {:error,
         [
           error(
             band["id"] || decision["id"],
             "the '#{@band_output}' output must be a string (got: #{band["type_ref"] || "none"})"
           )
         ]}

      true ->
        {:ok, band}
    end
  end

  defp no_default_entries(decision, table) do
    defaulted =
      Enum.filter(table["outputs"], fn output -> not is_nil(output["default_output_entry"]) end)

    case defaulted do
      [] ->
        :ok

      [first | _] ->
        {:error,
         [
           error(
             first["id"] || decision["id"],
             "the '#{first["name"]}' output carries a default output entry; a band table " <>
               "refuses a score it cannot place rather than defaulting it"
           )
         ]}
    end
  end

  # The engine types the decision variable against the table's compound output: a
  # multi-output table under a scalar `typeRef` compiles and verifies clean and then
  # type-errors on every evaluation. A band table that cannot answer must not land,
  # so the import refuses it here and names the one-attribute fix. A single-output
  # table keeps its `typeRef`: the scalar IS the output there, and it evaluates.
  defp evaluable_variable(xml, decision, table) do
    outputs = table["outputs"]

    if length(outputs) > 1 and is_binary(variable_type_ref(xml, decision)) do
      {:error,
       [
         error(
           decision["id"],
           "the decision variable of '#{decision["name"]}' declares a scalar typeRef but the " <>
             "table has #{length(outputs)} outputs; the engine types the variable against the " <>
             "compound output, so every evaluation would fail — drop the variable's typeRef"
         )
       ]}
    else
      :ok
    end
  end

  defp variable_type_ref(xml, decision) do
    case Xml.parse(xml) do
      {:ok, root} ->
        root
        |> Xml.descendants("decision")
        |> Enum.find(&(Xml.attr(&1, "id") == decision["id"]))
        |> variable_type_ref_of()

      {:error, _message} ->
        # The compiler already refused anything unparsable; this branch cannot
        # decide the contract, so it stays silent.
        nil
    end
  end

  defp variable_type_ref_of(nil), do: nil

  defp variable_type_ref_of(decision) do
    case Xml.child(decision, "variable") do
      nil -> nil
      variable -> Xml.attr(variable, "typeRef")
    end
  end

  defp error(path, message), do: %{path: path || "unknown", message: message}

  defp render(errors) when is_list(errors), do: Compiler.format_errors(errors)
  defp render(error) when is_exception(error), do: Exception.message(error)
  defp render(error), do: inspect(error)
end

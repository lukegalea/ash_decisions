# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Diff do
  @moduledoc """
  What changed between two versions of a decision definition, by what they mean.

  Two definitions are compared over their compiled snapshot (`graph`), never the XML, so
  moving a shape in the diagram or reformatting the document is not a change:

    * **decisions**: each decision by its id, added or removed, and for one in both its
      name, the decisions and inputs it requires, its hit policy and aggregation;
    * **inputs** and **outputs**: each clause of a decision table by its id, with its label,
      expression and type;
    * **rules**: each rule of a decision table by its id, with its input and output entries;
    * **input data**: the inputs the model declares.

  A literal-expression decision is compared by its expression text, which is what it
  evaluates. A definition that did not compile has no graph and compares as empty.

  The result is a list of plain maps, one per change, with no struct, so a host can render
  or store it without depending on a type from this package:

      %{
        aspect: :rules,                         # one of aspects/0
        kind: :added | :removed | :changed,
        subject: "decision_discount rule_gold", # the thing within the aspect
        option: "outputs" | nil,                # for :changed, the property that changed
        from: term(), to: term()                # the old and new value, as plain data
      }

  An empty list means nothing this compares changed. It does not mean the documents are
  identical; compare `content_hash` for that.
  """

  @typedoc "One change between two versions."
  @type change :: %{
          aspect: atom(),
          kind: :added | :removed | :changed,
          subject: String.t() | nil,
          option: String.t() | nil,
          from: term(),
          to: term()
        }

  @doc """
  What `diff/2` compares, in the order a reader should see it, each with an English label.
  A host translates the labels in its own catalogue.
  """
  @spec aspects() :: [{atom(), String.t()}]
  def aspects do
    [
      decisions: "Decisions",
      inputs: "Inputs",
      outputs: "Outputs",
      rules: "Rules",
      input_data: "Input data"
    ]
  end

  @doc "The changes from `old` to `new`, two definitions (or maps with a `:graph`)."
  @spec diff(map(), map()) :: [change()]
  def diff(old, new) do
    old_graph = graph(old)
    new_graph = graph(new)
    old_decisions = decisions(old_graph)
    new_decisions = decisions(new_graph)

    keyed(:decisions, heads(old_decisions), heads(new_decisions)) ++
      keyed(:inputs, clauses(old_decisions, "inputs"), clauses(new_decisions, "inputs")) ++
      keyed(:outputs, clauses(old_decisions, "outputs"), clauses(new_decisions, "outputs")) ++
      keyed(:rules, clauses(old_decisions, "rules"), clauses(new_decisions, "rules")) ++
      keyed(:input_data, input_data(old_graph), input_data(new_graph))
  end

  defp graph(%{graph: %{} = graph}), do: graph
  defp graph(_definition), do: %{}

  defp decisions(%{"decisions" => %{} = decisions}), do: decisions
  defp decisions(_graph), do: %{}

  # A decision without its table's clauses and rules, which are compared on their own.
  defp heads(decisions),
    do: Map.new(decisions, fn {id, d} -> {id, Map.drop(d, ["inputs", "outputs", "rules"])} end)

  # Each clause or rule keyed by its decision and its own id, so two tables' rules never
  # collide.
  defp clauses(decisions, part) do
    for {id, decision} <- decisions,
        clause <- decision[part] || [],
        into: %{},
        do: {"#{id} #{clause["id"]}", Map.delete(clause, "id")}
  end

  defp input_data(%{"input_data" => %{} = inputs}),
    do: Map.new(inputs, fn {id, input} -> {id, input["name"]} end)

  defp input_data(_graph), do: %{}

  # The changes between two maps of named subjects under `aspect`: added and removed names,
  # and, for a name in both, each property whose value differs. Values that are maps are
  # compared property by property; any other value is compared whole.
  defp keyed(aspect, old, new) do
    names = old |> Map.keys() |> Kernel.++(Map.keys(new)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(names, fn name ->
      case {Map.fetch(old, name), Map.fetch(new, name)} do
        {:error, {:ok, value}} -> [change(aspect, :added, name, nil, nil, value)]
        {{:ok, value}, :error} -> [change(aspect, :removed, name, nil, value, nil)]
        {{:ok, same}, {:ok, same}} -> []
        {{:ok, from}, {:ok, to}} -> properties(aspect, name, from, to)
      end
    end)
  end

  defp properties(aspect, name, %{} = from, %{} = to) do
    from
    |> Map.keys()
    |> Kernel.++(Map.keys(to))
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
    |> Enum.flat_map(fn option ->
      case {Map.get(from, option), Map.get(to, option)} do
        {same, same} -> []
        {old, new} -> [change(aspect, :changed, name, option, old, new)]
      end
    end)
  end

  defp properties(aspect, name, from, to), do: [change(aspect, :changed, name, nil, from, to)]

  defp change(aspect, kind, subject, option, from, to) do
    %{
      aspect: aspect,
      kind: kind,
      subject: subject && to_string(subject),
      option: option && to_string(option),
      from: from,
      to: to
    }
  end
end

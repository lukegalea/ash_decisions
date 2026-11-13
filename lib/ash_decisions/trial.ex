# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Trial do
  @moduledoc """
  Trying a decision version against sample inputs, before anyone relies on it.

  A trial is a question about the model, not a decision about a case. It evaluates the
  definition it is handed with `record: false` and names no evaluation resource, so no
  `Evaluation` row is written, no trace feeds the evidence trail, and nothing downstream can
  mistake a rehearsal for a real decision. The engine's own account of which rules matched
  comes back with the answer.

  Authority is the reader's own. Versions are read with the caller's `:actor` and `:tenant`
  through the definition resource's read policy, and **without** the context flag
  `AshDecisions.Scope.engine/2` sets, so the generated `AshDecisionsInteraction` bypass does
  not apply: someone who may not read a decision cannot try it, and a tenant cannot reach
  another tenant's draft. Nothing here runs as a system actor.

  `AshDecisions.Web.TryLive` is the page built on this module.
  """

  alias AshDecisions.Evaluator
  alias AshDecisions.Tck.Xml

  @typedoc "One input the document declares: its name and the FEEL type the author gave it."
  @type input :: %{name: String.t(), type: String.t() | nil}

  @typedoc "A matched rule, resolved to its 1-based position and description in the table."
  @type matched_rule :: %{
          id: String.t(),
          position: pos_integer() | nil,
          description: String.t() | nil
        }

  @doc """
  The versions of decision `key` the actor may read, newest first.

  `resource` is the host's definition resource. `opts` takes `:actor` and `:tenant`.

  An empty list means there is nothing to try, whether the key does not exist, belongs to
  another tenant, or the actor has no read on it; the three are indistinguishable by design.
  """
  @spec versions(module(), String.t(), keyword()) :: [struct()]
  def versions(resource, key, opts) when is_binary(key) do
    resource
    |> query(opts)
    |> Ash.Query.do_filter(key: key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.read()
    |> case do
      {:ok, versions} -> versions
      {:error, %Ash.Error.Forbidden{}} -> []
      {:error, error} -> raise error
    end
  end

  @doc """
  One version of `key` the actor may read, by id, or `nil`. A caller re-reads it on every
  trial rather than trusting a struct it kept.
  """
  @spec version(module(), String.t(), String.t(), keyword()) :: struct() | nil
  def version(resource, key, id, opts) when is_binary(key) and is_binary(id) do
    resource
    |> query(opts)
    |> Ash.Query.do_filter(key: key, id: id)
    |> Ash.read_one()
    |> case do
      {:ok, definition} -> definition
      # An id that is not a UUID, or a read the policy refuses outright.
      {:error, %Ash.Error.Invalid{}} -> nil
      {:error, %Ash.Error.Forbidden{}} -> nil
      {:error, error} -> raise error
    end
  end

  def version(_resource, _key, _id, _opts), do: nil

  # `do_filter/2` rather than the filter macro: the resource is only known at runtime and
  # the macro resolves bare field names statically.
  defp query(resource, opts) do
    Ash.Query.for_read(resource, :read, %{},
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant)
    )
  end

  @doc "The names of the decisions in a compiled definition; empty when it did not compile."
  @spec decisions(map()) :: [String.t()]
  def decisions(%{graph: %{"decisions" => decisions}}) when is_map(decisions) do
    decisions |> Map.values() |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  def decisions(_definition), do: []

  @doc "The inputs a document declares, in document order."
  @spec inputs(map()) :: [input()]
  def inputs(%{xml: xml}) when is_binary(xml) do
    case Xml.parse(xml) do
      {:ok, root} ->
        root
        |> Xml.descendants("inputData")
        |> Enum.map(fn element ->
          variable = Xml.child(element, "variable")
          %{name: Xml.attr(element, "name"), type: variable && Xml.attr(variable, "typeRef")}
        end)
        |> Enum.reject(&is_nil(&1.name))

      _ ->
        []
    end
  end

  def inputs(_definition), do: []

  @doc """
  Casts the text a person typed into the typed values the engine expects.

  Returns `{:ok, inputs}` or `{:error, %{name => reason}}` with one reason atom per field that
  could not be read: `:blank`, `:not_a_number`, `:not_a_boolean` or `:not_a_date`. Numbers
  become `Decimal`s, because FEEL numbers are decimal. A type this does not know is passed
  through as the text typed.
  """
  @spec cast([input()], map()) :: {:ok, map()} | {:error, %{String.t() => atom()}}
  def cast(declared, raw) when is_map(raw) do
    {values, errors} =
      Enum.reduce(declared, {%{}, %{}}, fn %{name: name, type: type}, {values, errors} ->
        case cast_one(type, raw |> Map.get(name, "") |> to_string() |> String.trim()) do
          {:ok, value} -> {Map.put(values, name, value), errors}
          {:error, reason} -> {values, Map.put(errors, name, reason)}
        end
      end)

    if errors == %{}, do: {:ok, values}, else: {:error, errors}
  end

  defp cast_one(_type, ""), do: {:error, :blank}

  defp cast_one(type, text) when type in ["number", "integer", "long", "double"] do
    case Decimal.parse(text) do
      {%Decimal{} = number, ""} ->
        if Decimal.nan?(number) or Decimal.inf?(number),
          do: {:error, :not_a_number},
          else: {:ok, number}

      _ ->
        {:error, :not_a_number}
    end
  end

  defp cast_one("boolean", "true"), do: {:ok, true}
  defp cast_one("boolean", "false"), do: {:ok, false}
  defp cast_one("boolean", _text), do: {:error, :not_a_boolean}

  defp cast_one("date", text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :not_a_date}
    end
  end

  defp cast_one(_type, text), do: {:ok, text}

  @doc """
  Evaluates `definition` against `inputs`, recording nothing.

  `decision` names the decision to evaluate when the document has more than one. The result
  is `AshDecisions.Evaluator`'s, with `:matched_rules` added: the matched rule ids resolved to
  their position and description in the document.
  """
  @spec run(struct(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def run(definition, inputs, decision \\ nil) do
    opts = if decision, do: [decision: decision, record: false], else: [record: false]

    with {:ok, result} <- Evaluator.evaluate(definition, inputs, opts) do
      {:ok, Map.put(result, :matched_rules, matched_rules(definition, result))}
    end
  end

  defp matched_rules(%{graph: %{"decisions" => decisions}}, result) when is_map(decisions) do
    rules =
      decisions
      |> Map.values()
      |> Enum.find(%{}, &(&1["name"] == result.decision))
      |> Map.get("rules", [])

    for id <- result.matched_rule_ids do
      case Enum.find_index(rules, &(&1["id"] == id)) do
        nil -> %{id: id, position: nil, description: nil}
        index -> %{id: id, position: index + 1, description: Enum.at(rules, index)["description"]}
      end
    end
  end

  defp matched_rules(_definition, result),
    do: Enum.map(result.matched_rule_ids, &%{id: &1, position: nil, description: nil})
end

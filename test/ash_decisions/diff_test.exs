# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.DiffTest do
  @moduledoc """
  `AshDecisions.Diff`: two versions compared by their compiled snapshot, as plain change
  maps. The compiled cases go through the real compiler, so a change to the snapshot's shape
  that the differ does not follow fails here.
  """

  use AshDecisions.DataCase, async: false

  alias AshDecisions.Diff
  alias AshDecisions.Scope
  alias AshDecisions.TenantTest.Definition

  @xml File.read!("test/fixtures/discount.dmn")

  defp compiled!(xml) do
    tenant = Ecto.UUID.generate()
    key = "k#{System.unique_integer([:positive])}"
    Definition.create!(%{key: key, name: key, xml: xml}, Scope.engine(%Scope{tenant: tenant}))
  end

  test "aspects are listed in reading order, each with a label" do
    assert Keyword.keys(Diff.aspects()) == [:decisions, :inputs, :outputs, :rules, :input_data]
    assert Enum.all?(Diff.aspects(), fn {_aspect, label} -> is_binary(label) end)
  end

  test "a version compared with itself has no changes" do
    definition = compiled!(@xml)
    assert Diff.diff(definition, definition) == []
  end

  test "a layout-only change to the document is not a change" do
    old = compiled!(@xml)
    new = compiled!(String.replace(@xml, "\n      <rule", "\n\n      <rule"))

    assert old.content_hash != new.content_hash
    assert Diff.diff(old, new) == []
  end

  test "a changed output entry is one rule change, naming its table and rule" do
    old = compiled!(@xml)

    new =
      compiled!(
        String.replace(
          @xml,
          ~s|<outputEntry id="rule_gold_large_2"><text>0.15</text>|,
          ~s|<outputEntry id="rule_gold_large_2"><text>0.20</text>|
        )
      )

    assert [
             %{
               aspect: :rules,
               kind: :changed,
               subject: "decision_discount rule_gold_large",
               option: option,
               from: from,
               to: to
             }
           ] = Diff.diff(old, new)

    assert is_binary(option)
    assert from != to
  end

  test "a removed rule and a new input are reported as such" do
    old = compiled!(@xml)

    new =
      @xml
      |> String.replace(~r|<rule id="rule_standard">.*?</rule>|s, "")
      |> String.replace(
        ~s|<inputData id="input_customer_tier"|,
        ~s|<inputData id="input_region" name="region">| <>
          ~s|<variable id="var_region" name="region" typeRef="string"/></inputData>| <>
          ~s|<inputData id="input_customer_tier"|
      )
      |> compiled!()

    changes = Diff.diff(old, new)

    assert %{kind: :removed, subject: "decision_discount rule_standard"} =
             Enum.find(changes, &(&1.aspect == :rules))

    assert %{kind: :added, subject: "input_region", to: "region"} =
             Enum.find(changes, &(&1.aspect == :input_data))
  end

  test "decision heads compare property by property, and tables per decision" do
    graph = fn hit_policy, output ->
      %{
        "input_data" => %{},
        "decisions" => %{
          "D" => %{
            "name" => "Triage",
            "hit_policy" => hit_policy,
            "inputs" => [%{"id" => "I", "expression" => "age"}],
            "outputs" => [%{"id" => "O", "name" => "band"}],
            "rules" => [%{"id" => "R", "input_entries" => ["> 65"], "output_entries" => [output]}]
          }
        }
      }
    end

    changes =
      Diff.diff(%{graph: graph.("FIRST", "\"high\"")}, %{graph: graph.("UNIQUE", "\"low\"")})

    assert %{aspect: :decisions, kind: :changed, subject: "D", option: "hit_policy"} =
             Enum.find(changes, &(&1.aspect == :decisions))

    assert %{
             aspect: :rules,
             subject: "D R",
             option: "output_entries",
             from: ["\"high\""],
             to: ["\"low\""]
           } = Enum.find(changes, &(&1.aspect == :rules))

    assert length(changes) == 2
  end

  test "a definition that did not compile compares as empty" do
    definition = compiled!(@xml)

    added = Diff.diff(%{graph: nil}, definition)

    assert added != []
    assert Enum.all?(added, &(&1.kind == :added))
    assert Diff.diff(%{graph: nil}, %{}) == []
  end
end

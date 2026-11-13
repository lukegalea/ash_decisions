# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.TrialTest do
  @moduledoc """
  `AshDecisions.Trial` without the page: what a version declares, how typed text becomes
  engine input, what a run answers, and that versions are read through the host's policy.
  """

  use AshDecisions.DataCase, async: false

  alias AshDecisions.Scope
  alias AshDecisions.Trial
  alias AshDecisions.TrialHost.{Definition, Evaluation}

  @xml File.read!("test/fixtures/discount.dmn")

  @described """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               id="described" name="described" namespace="urn:test">
    <inputData id="input_amount" name="amount">
      <variable id="var_amount" name="amount" typeRef="number"/>
    </inputData>
    <decision id="decision_tier" name="Tier">
      <informationRequirement id="req_amount">
        <requiredInput href="#input_amount"/>
      </informationRequirement>
      <decisionTable id="table_tier" hitPolicy="FIRST">
        <input id="clause_amount" label="Amount">
          <inputExpression id="expr_amount" typeRef="number"><text>amount</text></inputExpression>
        </input>
        <output id="clause_tier" name="tier" typeRef="string"/>
        <rule id="rule_high">
          <description>Large orders</description>
          <inputEntry id="rule_high_0"><text>&gt; 100</text></inputEntry>
          <outputEntry id="rule_high_1"><text>"high"</text></outputEntry>
        </rule>
        <rule id="rule_low">
          <inputEntry id="rule_low_0"><text>&lt;= 100</text></inputEntry>
          <outputEntry id="rule_low_1"><text>"low"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  setup do
    %{tenant: Ecto.UUID.generate(), key: "k#{System.unique_integer([:positive])}"}
  end

  defp create!(tenant, key, xml \\ @xml),
    do: Definition.create!(%{key: key, name: key, xml: xml}, Scope.engine(%Scope{tenant: tenant}))

  defp reader, do: %{id: Ecto.UUID.generate(), decisions?: true}

  describe "reading versions as the actor" do
    test "a reader in the tenant sees every version, newest first", %{tenant: t, key: key} do
      first = create!(t, key)
      Definition.publish!(first, Scope.engine(%Scope{tenant: t}))
      second = create!(t, key)

      assert [%{id: id2}, %{id: id1}] =
               Trial.versions(Definition, key, actor: reader(), tenant: t)

      assert {id2, id1} == {second.id, first.id}
    end

    test "the engine bypass does not apply: no read, nothing to try", %{tenant: t, key: key} do
      definition = create!(t, key)
      nobody = %{id: Ecto.UUID.generate(), decisions?: false}

      assert Trial.versions(Definition, key, actor: nobody, tenant: t) == []
      assert Trial.version(Definition, key, definition.id, actor: nobody, tenant: t) == nil
    end

    test "another tenant reads nothing, by key or by id", %{tenant: t, key: key} do
      definition = create!(t, key)
      other = Ecto.UUID.generate()

      assert Trial.versions(Definition, key, actor: reader(), tenant: other) == []
      assert Trial.version(Definition, key, definition.id, actor: reader(), tenant: other) == nil
    end

    test "an id must belong to the key, and must be an id", %{tenant: t, key: key} do
      definition = create!(t, key)
      opts = [actor: reader(), tenant: t]

      assert %{id: id} = Trial.version(Definition, key, definition.id, opts)
      assert id == definition.id
      assert Trial.version(Definition, "other", definition.id, opts) == nil
      assert Trial.version(Definition, key, "not-a-uuid", opts) == nil
      assert Trial.version(Definition, key, nil, opts) == nil
    end
  end

  describe "what a version declares" do
    test "inputs in document order, with their types" do
      assert Trial.inputs(%{xml: @xml}) == [
               %{name: "orderTotal", type: "number"},
               %{name: "customerTier", type: "string"}
             ]
    end

    test "no inputs from a document that does not parse, or no document" do
      assert Trial.inputs(%{xml: "<not dmn"}) == []
      assert Trial.inputs(%{}) == []
    end

    test "decision names from the compiled graph, and none without one", %{tenant: t, key: key} do
      assert Trial.decisions(create!(t, key)) == ["Discount"]
      assert Trial.decisions(%{graph: nil}) == []
    end
  end

  describe "casting typed text" do
    @declared [
      %{name: "n", type: "number"},
      %{name: "b", type: "boolean"},
      %{name: "d", type: "date"},
      %{name: "s", type: "string"},
      %{name: "u", type: nil}
    ]

    test "each type becomes what the engine expects" do
      assert {:ok, values} =
               Trial.cast(@declared, %{
                 "n" => " 3.50 ",
                 "b" => "true",
                 "d" => "2026-11-13",
                 "s" => "gold",
                 "u" => "as typed"
               })

      assert Decimal.equal?(values["n"], Decimal.new("3.50"))
      assert values["b"] == true
      assert values["d"] == ~D[2026-11-13]
      assert values["s"] == "gold"
      assert values["u"] == "as typed"
    end

    test "every field that cannot be read is named, with its reason" do
      assert Trial.cast(@declared, %{"n" => "NaN", "b" => "yes", "d" => "13/11/2026", "s" => " "}) ==
               {:error,
                %{
                  "n" => :not_a_number,
                  "b" => :not_a_boolean,
                  "d" => :not_a_date,
                  "s" => :blank,
                  "u" => :blank
                }}
    end
  end

  describe "running" do
    test "answers with the rules that matched, by position and description", %{
      tenant: t,
      key: key
    } do
      definition = create!(t, key, @described)

      assert {:ok, result} = Trial.run(definition, %{"amount" => Decimal.new(500)})
      assert result.outputs == "high"
      assert [%{id: "rule_high", position: 1, description: "Large orders"}] = result.matched_rules

      assert {:ok, low} = Trial.run(definition, %{"amount" => Decimal.new(5)}, "Tier")
      assert [%{id: "rule_low", position: 2, description: nil}] = low.matched_rules
    end

    test "records nothing", %{tenant: t, key: key} do
      definition = create!(t, key, @described)

      {:ok, _} = Trial.run(definition, %{"amount" => Decimal.new(500)})

      assert Evaluation
             |> Ash.Query.for_read(:read, %{}, authorize?: false, tenant: t)
             |> Ash.read!() == []
    end

    test "an engine refusal comes back as an error", %{tenant: t, key: key} do
      definition = create!(t, key, @described)

      assert {:error, _reason} = Trial.run(definition, %{"amount" => Decimal.new(5)}, "No such")
    end
  end
end

defmodule AshDecisions.CatalogueTest do
  @moduledoc """
  The catalogue projection: what a picker needs to know about a domain's
  decisions, and the cases where the honest answer is "nothing yet".
  """

  use AshDecisions.DataCase, async: false

  alias AshDecisions.Catalogue
  alias AshDecisions.Test.{Definition, Domain}

  @discount File.read!("test/fixtures/discount.dmn")
  @drd File.read!("test/fixtures/drd.dmn")
  @broken File.read!("test/fixtures/rule_order.dmn")

  # A table clause whose expression does not name the inputData it requires --
  # legal FEEL, and exactly the case where a type_ref cannot be found.
  @mismatch ~S"""
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               id="mismatch_definitions"
               name="Mismatch"
               namespace="https://ash-decisions.test/mismatch"
               expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
               typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
    <inputData id="input_price" name="price">
      <variable id="var_price" name="price" typeRef="number"/>
    </inputData>
    <decision id="decision_fee" name="Fee">
      <variable id="var_fee" name="fee" typeRef="number"/>
      <informationRequirement id="req_price">
        <requiredInput href="#input_price"/>
      </informationRequirement>
      <decisionTable id="table_fee" hitPolicy="UNIQUE">
        <input id="clause_total">
          <inputExpression id="expr_total" typeRef="number">
            <text>total</text>
          </inputExpression>
        </input>
        <output id="clause_fee" name="fee" typeRef="number"/>
        <rule id="rule_any">
          <inputEntry id="entry_any"><text>-</text></inputEntry>
          <outputEntry id="out_any"><text>0</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  defp key, do: "k#{System.unique_integer([:positive])}"

  defp published!(key, name, xml) do
    Definition.create!(%{key: key, name: name, xml: xml}) |> Definition.publish!()
  end

  defp entry_for(key), do: Catalogue.entries(Domain) |> Enum.find(&(&1.key == key))

  test "a domain with nothing in it has no entries" do
    assert Catalogue.entries(Domain) == []
  end

  test "a key with a draft and a published version reports the draft and the live version" do
    k = key()
    published!(k, "v1", @discount)
    Definition.create!(%{key: k, name: "v2 draft", xml: @drd})

    entry = entry_for(k)

    assert entry.status == :draft
    assert entry.name == "v2 draft"
    assert entry.has_draft == true
    assert entry.latest_published_version == 1
  end

  test "a published-only key projects the decisions of its snapshot" do
    k = key()
    published!(k, "Discount", @discount)

    entry = entry_for(k)

    assert entry.status == :published
    assert entry.name == "Discount"
    assert entry.has_draft == false
    assert entry.latest_published_version == 1

    assert [%{name: "Discount", inputs: inputs, outputs: outputs}] = entry.decisions

    assert inputs == [
             %{name: "orderTotal", type_ref: "number"},
             %{name: "customerTier", type_ref: "string"}
           ]

    assert outputs == [%{name: "discount", type_ref: "number"}]
  end

  test "latest_published_version ignores retired versions" do
    k = key()

    v1 = published!(k, "v1", @discount)
    Definition.retire!(v1)
    published!(k, "v2", @discount)
    v3 = published!(k, "v3", @discount)
    Definition.retire!(v3)

    assert entry_for(k).latest_published_version == 2
  end

  test "a key whose every version is retired does not appear" do
    k = key()
    only = published!(k, "only", @discount)
    Definition.retire!(only)

    refute Enum.any?(Catalogue.entries(Domain), &(&1.key == k))
  end

  test "a multi-decision document is projected in document order, with requires resolved" do
    k = key()
    published!(k, "Lending", @drd)

    entry = entry_for(k)
    assert Enum.map(entry.decisions, & &1.name) == ["Eligible", "Offer"]

    assert [
             %{name: "Eligible", inputs: eligible_inputs, outputs: eligible_outputs},
             %{name: "Offer", inputs: offer_inputs, outputs: offer_outputs}
           ] = entry.decisions

    # "age" is the name of the inputData the decision requires, and its type is
    # read off the table clause whose expression is that name.
    assert eligible_inputs == [%{name: "age", type_ref: "number"}]
    assert eligible_outputs == [%{name: "eligible", type_ref: "boolean"}]

    # A requirement on another decision is not an input. A literal expression
    # answers in the decision's variable, typed nowhere.
    assert offer_inputs == []
    assert offer_outputs == [%{name: "Offer", type_ref: nil}]
  end

  test "an uncompiled draft projects no decisions" do
    k = key()
    Definition.create!(%{key: k, name: "Broken", xml: @broken})

    entry = entry_for(k)

    assert entry.status == :draft
    assert entry.has_draft == true
    assert entry.latest_published_version == nil
    assert entry.decisions == []
  end

  test "an uncompiled draft falls back to the last published snapshot" do
    k = key()
    published!(k, "v1", @discount)
    Definition.create!(%{key: k, name: "v2 draft", xml: @broken})

    entry = entry_for(k)

    assert entry.status == :draft
    assert [%{name: "Discount"}] = entry.decisions
  end

  test "an input's type_ref is nil when no table clause's expression names it" do
    k = key()
    published!(k, "Mismatch", @mismatch)

    assert [
             %{
               name: "Fee",
               inputs: [%{name: "price", type_ref: nil}],
               outputs: [%{name: "fee", type_ref: "number"}]
             }
           ] = entry_for(k).decisions
  end

  test "entries accept either shape of :scope" do
    k = key()
    published!(k, "Discount", @discount)

    assert [%{key: ^k}] = Catalogue.entries(Domain, scope: [actor: nil, tenant: nil])
    assert [%{key: ^k}] = Catalogue.entries(Domain, scope: AshDecisions.Scope.system())
    assert [%{key: ^k}] = Catalogue.entries(Domain, scope: %AshDecisions.Scope{})
  end
end

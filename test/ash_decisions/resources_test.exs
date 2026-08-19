defmodule AshDecisions.ResourcesTest do
  @moduledoc """
  The definition lifecycle, and the record of what a decision decided.

  A decision definition is not a row that happens to hold some XML. It is a
  versioned artifact with exactly one editable state, a compile result attached
  to it at all times, and a publish step that refuses to run over a compile
  error — and those three properties are what let everything downstream stop
  asking whether the rules it is about to run are the rules somebody approved.
  """

  use AshDecisions.DataCase, async: false

  require Ash.Query

  alias AshDecisions.Test.{Definition, Domain, Evaluation}

  @discount File.read!("test/fixtures/discount.dmn")
  @drd File.read!("test/fixtures/drd.dmn")
  @broken File.read!("test/fixtures/rule_order.dmn")

  defp key, do: "k#{System.unique_integer([:positive])}"

  describe "creating a draft" do
    test "compiles the document and stores the snapshot beside it" do
      definition = Definition.create!(%{key: key(), name: "Discount", xml: @discount})

      assert definition.status == :draft
      assert definition.version == 1
      assert definition.errors == []
      assert definition.graph["decisions"]["decision_discount"]["hit_policy"] == "UNIQUE"
      assert definition.graph["decisions"]["decision_discount"]["logic"] == "decisionTable"
    end

    test "the content hash is the sha256 of the document, so a snapshot can be tied to its source" do
      definition = Definition.create!(%{key: key(), name: "Discount", xml: @discount})

      assert definition.content_hash ==
               :crypto.hash(:sha256, @discount) |> Base.encode16(case: :lower)
    end

    test "a document that does not compile is stored as a draft carrying its errors" do
      definition = Definition.create!(%{key: key(), name: "Rule order", xml: @broken})

      assert definition.status == :draft
      assert definition.graph == nil
      assert [%{"message" => message, "path" => "table_discount"}] = definition.errors
      assert message =~ "RULE ORDER"
    end

    test "a second draft for the same key is refused" do
      k = key()
      Definition.create!(%{key: k, name: "Discount", xml: @discount})

      assert {:error, %Ash.Error.Invalid{} = error} =
               Definition.create(%{key: k, name: "Discount again", xml: @discount})

      assert Exception.message(error) =~ "a draft already exists for this key"
    end

    test "versions are assigned per key" do
      k = key()
      other = key()

      first = Definition.create!(%{key: k, name: "Discount", xml: @discount})
      Definition.publish!(first)
      second = Definition.create!(%{key: k, name: "Discount", xml: @discount})

      assert second.version == 2
      assert Definition.create!(%{key: other, name: "Other", xml: @discount}).version == 1
    end
  end

  describe "save_xml" do
    test "recompiles the snapshot from the new document" do
      definition = Definition.create!(%{key: key(), name: "Discount", xml: @discount})
      updated = Definition.save_xml!(definition, @drd)

      assert Map.keys(updated.graph["decisions"]) |> Enum.sort() ==
               ["decision_eligible", "decision_offer"]

      assert updated.content_hash != definition.content_hash
    end

    test "a document that stops compiling clears the snapshot and records why" do
      definition = Definition.create!(%{key: key(), name: "Discount", xml: @discount})
      updated = Definition.save_xml!(definition, @broken)

      assert updated.graph == nil
      assert [%{"message" => message}] = updated.errors
      assert message =~ "RULE ORDER"
    end

    test "a published definition cannot be edited" do
      definition =
        Definition.create!(%{key: key(), name: "Discount", xml: @discount})
        |> Definition.publish!()

      assert {:error, error} = Definition.save_xml(definition, @drd)
      assert Exception.message(error) =~ "can only perform this action on a draft"
    end
  end

  describe "publish" do
    test "moves a compiling draft to published" do
      published =
        Definition.create!(%{key: key(), name: "Discount", xml: @discount})
        |> Definition.publish!()

      assert published.status == :published
    end

    test "refuses a draft that carries compile errors" do
      definition = Definition.create!(%{key: key(), name: "Rule order", xml: @broken})

      assert {:error, error} = Definition.publish(definition)
      assert Exception.message(error) =~ "cannot publish a definition with compile errors"
    end

    test "refuses anything that is not a draft" do
      published =
        Definition.create!(%{key: key(), name: "Discount", xml: @discount})
        |> Definition.publish!()

      assert {:error, error} = Definition.publish(published)
      assert Exception.message(error) =~ "can only perform this action on a draft"
    end
  end

  describe "retire" do
    test "moves a published definition to retired" do
      retired =
        Definition.create!(%{key: key(), name: "Discount", xml: @discount})
        |> Definition.publish!()
        |> Definition.retire!()

      assert retired.status == :retired
    end

    test "refuses a draft" do
      definition = Definition.create!(%{key: key(), name: "Discount", xml: @discount})

      assert {:error, error} = Definition.retire(definition)
      assert Exception.message(error) =~ "can only retire a published definition"
    end
  end

  describe "reading" do
    test "latest_published returns the highest published version and ignores drafts" do
      k = key()

      Definition.create!(%{key: k, name: "v1", xml: @discount}) |> Definition.publish!()
      Definition.create!(%{key: k, name: "v2", xml: @discount}) |> Definition.publish!()
      Definition.create!(%{key: k, name: "v3 draft", xml: @discount})

      assert [latest] = Definition.latest_published!(k)
      assert latest.version == 2
      assert latest.name == "v2"
    end

    test "latest_published returns nothing for a key that has never been published" do
      k = key()
      Definition.create!(%{key: k, name: "draft only", xml: @discount})

      assert Definition.latest_published!(k) == []
    end

    test "by_key_version fetches by identity" do
      k = key()
      Definition.create!(%{key: k, name: "Discount", xml: @discount})

      assert %{name: "Discount"} = Definition.by_key_version!(k, 1)

      assert_raise Ash.Error.Invalid, fn -> Definition.by_key_version!(k, 99) end
    end
  end

  describe "evaluations" do
    test "record one row per invoked decision, tied back to the definition by key and version" do
      definition =
        Definition.create!(%{key: key(), name: "Discount", xml: @discount})
        |> Definition.publish!()

      correlation = Ecto.UUID.generate()

      evaluation =
        Evaluation.create!(%{
          definition_id: definition.id,
          definition_key: definition.key,
          definition_version: definition.version,
          decision_id: "decision_discount",
          inputs: %{"orderTotal" => 1200, "customerTier" => "gold"},
          outputs: %{"discount" => 0.15},
          matched_rule_ids: ["rule_gold_large"],
          hit_policy: "UNIQUE",
          duration_us: 412,
          correlation_id: correlation
        })

      assert evaluation.matched_rule_ids == ["rule_gold_large"]
      assert evaluation.outputs == %{"discount" => 0.15}
      assert evaluation.error == nil
    end

    test "a decision that could not answer is recorded, not swallowed" do
      definition = Definition.create!(%{key: key(), name: "Discount", xml: @discount})

      evaluation =
        Evaluation.create!(%{
          definition_id: definition.id,
          definition_key: definition.key,
          definition_version: definition.version,
          decision_id: "decision_discount",
          inputs: %{"orderTotal" => "not a number"},
          error: %{"code" => "type_error", "message" => "expected a number"}
        })

      assert evaluation.error["code"] == "type_error"
      assert evaluation.outputs == %{}
    end

    test "the resource is append-only: there is no update and no destroy" do
      action_types =
        Evaluation
        |> Ash.Resource.Info.actions()
        |> Enum.map(& &1.type)
        |> Enum.uniq()
        |> Enum.sort()

      assert action_types == [:create, :read]
    end
  end

  describe "introspection" do
    test "each macro marks the module it generated" do
      assert Definition.ash_decisions_kind() == :definition
      assert Evaluation.ash_decisions_kind() == :evaluation
    end

    test "a module that is not one of ours is reported as such" do
      assert AshDecisions.Resources.kind(AshDecisions.TestRepo) == :not_ash_decisions
      assert AshDecisions.Resources.kind(Enum) == :not_ash_decisions
    end

    test "for_domain locates both kinds" do
      assert {:ok, %{definition: Definition, evaluation: Evaluation}} =
               AshDecisions.Resources.for_domain(Domain)
    end

    test "for_domain says which kind is missing rather than crashing" do
      assert {:error, :missing_resources, missing} =
               AshDecisions.Resources.for_domain(AshDecisions.PartialTest.Domain)

      assert missing == [:evaluation]
    end
  end
end

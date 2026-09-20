# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.VerificationResourceTest do
  @moduledoc """
  The publish path, now with verification in it.

  The contract this must not break: `errors` non-empty is a valid draft state
  and is what `ErrorsEmpty` uses to stop a publish. Verification is a sibling of
  `errors`, never an addition to it — and only error-severity findings block,
  which is what keeps an undecidable table a fact an auditor reads rather than a
  publish an author cannot make.
  """

  use AshDecisions.DataCase, async: false

  alias AshDecisions.Test.Definition

  @overlap File.read!("test/fixtures/verification_overlap.dmn")
  @incomplete File.read!("test/fixtures/verification_incomplete.dmn")
  @defaulted File.read!("test/fixtures/verification_default.dmn")
  @malformed File.read!("test/fixtures/verification_malformed.dmn")
  @opaque_xml File.read!("test/fixtures/verification_opaque.dmn")
  @clean File.read!("test/fixtures/discount.dmn")

  defp key, do: "k#{System.unique_integer([:positive])}"

  describe "the verification attribute" do
    test "a draft carries the verification result beside its snapshot" do
      definition = Definition.create!(%{key: key(), name: "Overlap", xml: @overlap})

      assert %{"obligations" => [], "verifier_version" => version} = definition.verification

      finding = Enum.find(definition.verification["findings"], &(&1["kind"] == "overlap"))

      assert finding["severity"] == "error"
      assert is_binary(version)
    end

    test "an undecidable draft carries its obligations, not an error" do
      definition = Definition.create!(%{key: key(), name: "Opaque", xml: @opaque_xml})

      assert definition.verification["findings"] == []

      assert [%{"reason" => "opaque_entry"}] = definition.verification["obligations"]
    end

    test "a draft that does not compile carries neither snapshot nor verification" do
      broken = File.read!("test/fixtures/rule_order.dmn")
      definition = Definition.create!(%{key: key(), name: "Broken", xml: broken})

      assert definition.graph == nil
      assert definition.verification == nil
      assert definition.errors != []
    end

    test "save_xml re-verifies the new document" do
      definition = Definition.create!(%{key: key(), name: "Overlap", xml: @overlap})
      updated = Definition.save_xml!(definition, @defaulted)

      assert updated.verification["findings"] == []
    end
  end

  describe "publish" do
    test "a UNIQUE overlap is an error-severity finding, and blocks the publish" do
      definition = Definition.create!(%{key: key(), name: "Overlap", xml: @overlap})

      assert {:error, error} = Definition.publish(definition)

      message = Exception.message(error)
      assert message =~ "cannot publish"
      assert message =~ "verification"
      assert message =~ "rule_gold_large"
    end

    test "a malformed input entry blocks the publish" do
      definition = Definition.create!(%{key: key(), name: "Malformed", xml: @malformed})

      assert definition.errors == []

      assert {:error, error} = Definition.publish(definition)
      assert Exception.message(error) =~ "malformed"
    end

    test "warnings and obligations publish: an incomplete table is a warning" do
      definition = Definition.create!(%{key: key(), name: "Incomplete", xml: @incomplete})
      published = Definition.publish!(definition)

      assert published.status == :published

      assert [%{"kind" => "incomplete", "severity" => "warning"}] =
               published.verification["findings"]
    end

    test "an undecidable table publishes, with its obligations on the row" do
      definition = Definition.create!(%{key: key(), name: "Opaque", xml: @opaque_xml})
      published = Definition.publish!(definition)

      assert published.status == :published
      assert [%{"reason" => "opaque_entry"}] = published.verification["obligations"]
    end

    test "a clean table publishes" do
      definition = Definition.create!(%{key: key(), name: "Clean", xml: @clean})
      published = Definition.publish!(definition)

      assert published.status == :published
      # discount.dmn has no overlap, but its tier column does not cover
      # unknown tiers: the warning is exactly what publish-time verification is
      # for, and it does not block.
      assert [%{"kind" => "incomplete", "severity" => "warning"}] =
               published.verification["findings"]
    end

    test "a defaulted table publishes with nothing to report" do
      definition = Definition.create!(%{key: key(), name: "Defaulted", xml: @defaulted})
      published = Definition.publish!(definition)

      assert published.status == :published
      assert published.verification["findings"] == []
    end

    test "a draft saved before verification existed is verified on the fly at publish" do
      definition = Definition.create!(%{key: key(), name: "Clean", xml: @clean})

      # Simulate a row from before the column meant anything: no stored result.
      # Publish must still verify — computing on the fly — rather than wave the
      # draft through on a missing field.
      published =
        %{definition | verification: nil}
        |> Ash.Changeset.for_update(:publish)
        |> Ash.update!(AshDecisions.Scope.engine(%AshDecisions.Scope{}))

      assert published.status == :published
    end

    test "config can escalate incompleteness to a publish-blocking error" do
      Application.put_env(:ash_decisions, :incomplete_tables, :error)

      on_exit(fn -> Application.delete_env(:ash_decisions, :incomplete_tables) end)

      definition = Definition.create!(%{key: key(), name: "Incomplete", xml: @incomplete})

      assert {:error, error} = Definition.publish(definition)
      assert Exception.message(error) =~ "cannot publish"
    end
  end
end

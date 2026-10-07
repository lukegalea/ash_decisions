# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.BandTableTest do
  @moduledoc """
  The band-table landing (AST-52): the calibration renderer's golden
  document through import, the ordinary lifecycle, and evaluation back to
  the bands the goldens promise — plus every clause of the import contract
  that refuses a document which is not a band table, or is one that could
  not answer.
  """

  use AshDecisions.DataCase, async: false

  alias AshDecisions.BandTable
  alias AshDecisions.Test.Definition

  # The calibration renderer's committed golden document, byte-identical
  # (test/proposal_dmn_test.exs in ash_judgments, commit 0223689).
  @golden File.read!("test/fixtures/band_table.dmn")

  # The golden with the one attribute removed that the import contract
  # names: the decision variable's scalar typeRef. The only delta from the
  # generator's output, kept next to the assertions that consume it.
  @roundtrip String.replace(
               @golden,
               ~s( typeRef="string"/>\n    <informationRequirement id="req_p_supports">),
               ~s(/>\n    <informationRequirement id="req_p_supports">)
             )

  describe "import_document/2" do
    test "the golden's shape imports to create attributes, XML verbatim" do
      assert {:ok, attrs} = BandTable.import_document(@roundtrip)

      assert attrs.key == "bands_clinic_triage"
      assert attrs.name == "bands_clinic_triage"
      assert attrs.xml == @roundtrip
    end

    test "the display name is overridable; the key is not" do
      assert {:ok, attrs} =
               BandTable.import_document(@roundtrip, name: "Clinic triage bands")

      assert attrs.name == "Clinic triage bands"
      assert attrs.key == "bands_clinic_triage"
    end

    @tag :upstream_tripwire
    test "the generator's current golden is refused, naming the one-attribute fix" do
      # The renderer writes typeRef="string" on a two-output table's decision
      # variable. The engine types the variable against the compound output,
      # so that document compiles and verifies clean and then type-errors on
      # every evaluation — exactly what the import contract exists to stop.
      #
      # This assertion is a tripwire across the lane boundary: when
      # ash_judgments drops the scalar typeRef, this test fails, and the
      # golden round-trips byte-identically below instead.
      assert {:error, [%{path: "decision_bands_clinic_triage", message: message}]} =
               BandTable.import_document(@golden)

      assert message =~ "scalar typeRef"
      assert message =~ "drop the variable's typeRef"
    end

    test "a FIRST policy is refused: one band per case, no answer by rule order" do
      xml = String.replace(@roundtrip, ~s(hitPolicy="UNIQUE"), ~s(hitPolicy="FIRST"))

      assert {:error, [%{message: message}]} = BandTable.import_document(xml)
      assert message =~ "UNIQUE"
    end

    test "a default output entry is refused: the refusal must stay a refusal" do
      xml =
        String.replace(
          @roundtrip,
          ~s(<output id="clause_band" name="band" label="band" typeRef="string"/>),
          ~s(<output id="clause_band" name="band" label="band" typeRef="string">) <>
            ~s(<defaultOutputEntry><text>"review"</text></defaultOutputEntry>) <>
            ~s(</output>)
        )

      assert {:error, [%{path: "clause_band", message: message}]} = BandTable.import_document(xml)
      assert message =~ "default output entry"
      assert message =~ "refuses a score it cannot place"
    end

    test "a second decision is refused" do
      xml =
        String.replace(
          @roundtrip,
          "</definitions>",
          """
            <decision id="decision_second" name="second">
              <literalExpression><text>1</text></literalExpression>
            </decision>
          </definitions>
          """
        )

      assert {:error, [%{path: "definitions", message: message}]} = BandTable.import_document(xml)
      assert message =~ "one decision"
      assert message =~ "2"
    end

    test "a decision that is not a table is refused" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/" id="lit_defs" name="lit" namespace="urn:lit">
        <decision id="decision_lit" name="lit_decision">
          <literalExpression><text>1</text></literalExpression>
        </decision>
      </definitions>
      """

      assert {:error, [%{path: "decision_lit", message: message}]} =
               BandTable.import_document(xml)

      assert message =~ "literalExpression"
      assert message =~ "not a decision table"
    end

    test "no output named band is refused" do
      xml =
        String.replace(
          @roundtrip,
          ~s(name="band" label="band"),
          ~s(name="verdict" label="verdict")
        )

      assert {:error, [%{message: message}]} = BandTable.import_document(xml)
      assert message =~ "no output named 'band'"
    end

    test "a non-string band output is refused" do
      xml =
        String.replace(
          @roundtrip,
          ~s(<output id="clause_band" name="band" label="band" typeRef="string"/>),
          ~s(<output id="clause_band" name="band" label="band" typeRef="number"/>)
        )

      assert {:error, [%{path: "clause_band", message: message}]} = BandTable.import_document(xml)
      assert message =~ "must be a string"
    end

    test "a document that does not compile reports the compiler's errors" do
      assert {:error, [%{message: message}]} = BandTable.import_document("<not-dmn/>")
      assert message =~ "the engine rejected the model"
    end
  end

  describe "land/3" do
    test "the golden's shape lands as a published policy through the ordinary lifecycle" do
      assert {:ok, published} = BandTable.land(Definition, @roundtrip)

      assert published.status == :published
      assert published.version == 1
      assert published.key == "bands_clinic_triage"
      assert published.name == "bands_clinic_triage"
      assert published.errors == []
      # Rule 7: the stored document is the landed document, byte for byte.
      assert published.xml == @roundtrip
      assert is_binary(published.content_hash)
    end

    test "publish-time verification ran, and found nothing" do
      {:ok, published} = BandTable.land(Definition, @roundtrip)

      # The two bands partition the score's domain (`>= t`, `< t`), so the
      # table is provably complete and non-overlapping.
      assert published.verification["findings"] == []
      assert published.verification["obligations"] == []
    end

    test "publish?: false stops at the draft" do
      assert {:ok, draft} = BandTable.land(Definition, @roundtrip, publish?: false)
      assert draft.status == :draft
    end

    test "an import refusal lands nothing" do
      xml = String.replace(@roundtrip, ~s(hitPolicy="UNIQUE"), ~s(hitPolicy="FIRST"))

      assert {:error, [_finding]} = BandTable.land(Definition, xml)
      assert {:error, _not_found} = Definition.by_key_version("bands_clinic_triage", 1)
    end

    test "a configured publish verifier's refusal holds the draft" do
      Application.put_env(:ash_decisions, :publish_verifiers, [
        {__MODULE__.RefusingGate, :verify, ["the calibration run is below min_n"]}
      ])

      on_exit(fn -> Application.delete_env(:ash_decisions, :publish_verifiers) end)

      assert {:error, error} = BandTable.land(Definition, @roundtrip)
      assert Exception.message(error) =~ "the calibration run is below min_n"

      assert Definition.by_key_version!("bands_clinic_triage", 1).status == :draft
    end

    test "import_document! raises on an import refusal with the findings formatted" do
      xml = String.replace(@roundtrip, ~s(hitPolicy="UNIQUE"), ~s(hitPolicy="FIRST"))

      assert_raise(RuntimeError, ~r/not a band table/, fn ->
        BandTable.import_document!(xml)
      end)
    end
  end

  describe "the golden round-trip: land, then evaluate" do
    setup do
      {:ok, published} = BandTable.land(Definition, @roundtrip)
      %{definition: published}
    end

    test "a score above the threshold admits, with the golden's reason code", %{
      definition: definition
    } do
      result =
        AshDecisions.Evaluator.evaluate!(definition, %{"p_supports" => Decimal.new("0.95")})

      assert result.outputs == %{
               "band" => "admit",
               "reason_code" => "conformal_threshold_met"
             }

      assert result.matched_rule_ids == ["rule_admit"]
      assert result.hit_policy == "UNIQUE"
    end

    test "the threshold itself admits — the golden's >= boundary", %{definition: definition} do
      result =
        AshDecisions.Evaluator.evaluate!(definition, %{"p_supports" => Decimal.new("0.93")})

      assert result.outputs["band"] == "admit"
      assert result.matched_rule_ids == ["rule_admit"]
    end

    test "a score below the threshold reviews, with the golden's reason code", %{
      definition: definition
    } do
      result =
        AshDecisions.Evaluator.evaluate!(definition, %{"p_supports" => Decimal.new("0.92")})

      assert result.outputs == %{
               "band" => "review",
               "reason_code" => "below_conformal_threshold"
             }

      assert result.matched_rule_ids == ["rule_review"]
    end

    test "a null score matches nothing — the refusal the missing default rule buys", %{
      definition: definition
    } do
      # The malformed-score shape a pipeline actually feeds: the evidence is
      # absent or unparseable, so the score arrives as null. No row matches,
      # and because there is no default rule that empty match stays a refusal.
      result = AshDecisions.Evaluator.evaluate!(definition, %{"p_supports" => nil})

      assert result.outputs == nil
      assert result.matched_rule_ids == []
    end
  end

  defmodule RefusingGate do
    @moduledoc false
    def verify(reason, _definition), do: {:error, reason}
  end
end

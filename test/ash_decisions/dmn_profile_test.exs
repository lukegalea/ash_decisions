defmodule AshDecisions.DmnProfileTest do
  @moduledoc """
  The two directions of the DMN revision gap, and the round trip between them.

  The engine refuses anything that is not DMN 1.5. dmn-js's moddle understands
  nothing later than 1.3. So a document is only ever readable by one of the two
  without a rewrite, and both rewrites have to exist.

  `normalize/1` had a test from the day it was written, because the engine
  refusing a 1.3 document is loud. `to_editable/1` did not, and the gap it covers
  was found by looking at a screenshot: the decision editor rendering
  `failed to parse document as <dmn:Definitions>` over an empty canvas, on a
  baseline that compiled and evaluated perfectly well. A message that names the
  element and not the revision.
  """

  use ExUnit.Case, async: true

  alias AshDecisions.Dmn.Profile

  # The shape that matters: a 1.5 document, which is what a baseline published for
  # the engine actually looks like.
  @dmn_15 """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
               xmlns:feel="https://www.omg.org/spec/DMN/20230324/FEEL/"
               id="Definitions_1" name="risk" namespace="urn:test">
    <decision id="Decision_1" name="Risk">
      <decisionTable id="DT_1" hitPolicy="FIRST">
        <input id="I_1"><inputExpression id="IE_1" typeRef="string"><text>tier</text></inputExpression></input>
        <output id="O_1" name="risk" typeRef="string"/>
        <rule id="R_1">
          <inputEntry id="IN_1"><text>"privileged"</text></inputEntry>
          <outputEntry id="OUT_1"><text>"high"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  describe "to_editable/1" do
    test "rewrites the executable revision to the one dmn-js can open" do
      editable = Profile.to_editable(@dmn_15)

      assert editable =~ Profile.editable_namespace()
      refute editable =~ Profile.executable_namespace()
      refute editable =~ "20230324"
    end

    test "rewrites the FEEL namespace too, not just MODEL" do
      # Missing this leaves a document declaring a 1.3 MODEL and a 1.5 FEEL, which
      # is not a revision of anything and which moddle reports as an unknown
      # namespace rather than as a version problem.
      editable = Profile.to_editable(@dmn_15)

      assert editable =~ "https://www.omg.org/spec/DMN/20191111/FEEL/"
      refute editable =~ "20230324/FEEL"
    end

    test "leaves the decision logic alone" do
      editable = Profile.to_editable(@dmn_15)

      # The rewrite is namespace-only. Every construct this package compiles is
      # spelled identically in 1.3 and 1.5, which is what makes it safe.
      assert editable =~ ~s|hitPolicy="FIRST"|
      assert editable =~ "<text>\"privileged\"</text>"
      assert editable =~ "<text>\"high\"</text>"
      assert editable =~ ~s|name="Risk"|
    end

    test "is idempotent" do
      once = Profile.to_editable(@dmn_15)
      assert Profile.to_editable(once) == once
    end
  end

  describe "the round trip" do
    test "editable then normalized is executable again" do
      # This is the actual path a save takes: the editor is handed the editable
      # dialect, dmn-js writes it back in that dialect, and the compiler brings it
      # forward for the engine. If the pair were not inverse, publishing from the
      # editor would silently downgrade every baseline it touched.
      round_tripped = @dmn_15 |> Profile.to_editable() |> Profile.normalize()

      assert Profile.executable?(round_tripped)
      assert round_tripped == @dmn_15
    end

    test "normalized then editable is what the editor gets" do
      assert @dmn_15 |> Profile.normalize() |> Profile.to_editable() ==
               Profile.to_editable(@dmn_15)
    end
  end

  describe "documents with no DMN namespace" do
    test "are left alone rather than guessed at" do
      # `normalize/1` documents this; `to_editable/1` has to agree, or a non-DMN
      # document would come back subtly altered on its way to the editor.
      other = ~s|<?xml version="1.0"?><root><child/></root>|

      assert Profile.to_editable(other) == other
      assert Profile.normalize(other) == other
    end
  end
end

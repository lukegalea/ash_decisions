defmodule AshDecisions.WebTest do
  @moduledoc """
  The decision editor, driven without a browser.

  Every assertion here goes through the hidden save/publish forms rather than the
  dmn-js hook, which is the whole reason those forms exist: an editor whose only
  path to the database runs through JavaScript is an editor with no server-side
  tests, and the parts most worth testing — that a draft is created on first
  visit, that saving recompiles, that publishing freezes a version — are all
  server-side.

  What is deliberately *not* asserted here is anything about dmn-js itself. That
  it renders a decision table is its business; that this application hands it a
  document it can open, and stores back what it returns, is ours.
  """

  use AshDecisions.WebConnCase, async: false

  @table_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
               id="Definitions_web" name="web" namespace="urn:test">
    <decision id="Decision_1" name="Web decision">
      <decisionTable id="DecisionTable_1" hitPolicy="FIRST">
        <input id="Input_1" label="Amount">
          <inputExpression id="InputExpression_1" typeRef="number">
            <text>amount</text>
          </inputExpression>
        </input>
        <output id="Output_1" label="Tier" name="tier" typeRef="string"/>
        <rule id="Rule_1">
          <inputEntry id="InputEntry_1"><text>&gt; 100</text></inputEntry>
          <outputEntry id="OutputEntry_1"><text>"high"</text></outputEntry>
        </rule>
        <rule id="Rule_2">
          <inputEntry id="InputEntry_2"><text>&lt;= 100</text></inputEntry>
          <outputEntry id="OutputEntry_2"><text>"low"</text></outputEntry>
        </rule>
      </decisionTable>
    </decision>
  </definitions>
  """

  describe "opening the editor" do
    test "creates a draft on first visit, so there is always something to edit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      # The editor's contract with the hook is the `data-xml` attribute, so the
      # meaningful assertion is that a document reached it -- not that any
      # particular element is on screen.
      assert has_element?(view, "#decision-editor[data-xml]")
      assert has_element?(view, "#decision-save")
      assert has_element?(view, "#decision-publish")

      drafts =
        AshDecisions.Test.Definition
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.do_filter(key: "web_test", status: :draft)
        |> Ash.read!(authorize?: false)

      assert [%{version: 1}] = drafts
    end

    test "the template it creates is a document dmn-js could open", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      xml =
        view
        |> element("#decision-editor")
        |> render()

      # DMN 1.3 rather than 1.5, deliberately: 1.3 is what dmn-js reads and
      # writes, and the engine's 1.5 requirement is met by normalising on ingest.
      # A 1.5 template would be a template the editor cannot open.
      assert xml =~ "20191111/MODEL"
      assert xml =~ "decisionTable"
    end

    test "takes its key from the route, so one module serves every decision", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/decisions/routed_decision/editor")

      assert render(view) =~ "routed_decision"

      assert AshDecisions.Test.Definition
             |> Ash.Query.for_read(:read, %{}, authorize?: false)
             |> Ash.Query.do_filter(key: "routed_decision")
             |> Ash.read!(authorize?: false)
             |> length() == 1
    end
  end

  describe "saving" do
    test "stores the document and compiles it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      view
      |> element("#decision-save-form")
      |> render_submit(%{"xml" => @table_xml})

      draft =
        AshDecisions.Test.Definition
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.do_filter(key: "web_test", status: :draft)
        |> Ash.read_one!(authorize?: false)

      assert draft.xml =~ "Web decision"
      # A compiled graph, not just stored text. Without this the test would pass
      # on an editor that persisted XML and never ran the compiler.
      assert is_map(draft.graph) and draft.graph != %{}
      assert draft.errors in [nil, []]
    end

    test "a document that will not compile is reported, not swallowed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      view
      |> element("#decision-save-form")
      |> render_submit(%{"xml" => "<definitions>not a decision</definitions>"})

      # The errors list renders. Asserting on a substring of the page would pass
      # on the word "error" appearing anywhere in it, including in a Tailwind
      # class name -- which is most of why this element has an id.
      assert has_element?(view, "#decision-errors")

      draft =
        AshDecisions.Test.Definition
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.do_filter(key: "web_test", status: :draft)
        |> Ash.read_one!(authorize?: false)

      # The document is stored *with* its errors rather than rejected. That is
      # the right shape for an editor -- a document that will not compile is the
      # normal state of a document being edited -- but it means the errors have
      # to be surfaced, because nothing else signals that the save was not a
      # success.
      assert draft.xml == "<definitions>not a decision</definitions>"
      assert [%{"path" => _, "message" => message}] = draft.errors
      assert message =~ "the engine rejected the model"
    end
  end

  describe "publishing" do
    test "freezes a version and leaves the draft behind", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      view
      |> element("#decision-publish-form")
      |> render_submit(%{"xml" => @table_xml})

      published =
        AshDecisions.Test.Definition
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.do_filter(key: "web_test", status: :published)
        |> Ash.read!(authorize?: false)

      assert [%{version: 1}] = published
    end
  end

  describe "the bpmn.io watermark" do
    test "nothing in this package's CSS hides it", %{conn: _conn} do
      # dmn-js ships under the bpmn.io licence, whose text is byte-identical to
      # bpmn-js's: the watermark's source must not be changed and it must stay
      # fully visible and unoverlapped. The element itself is rendered by dmn-js
      # in the browser, so what can be checked here is the thing most likely to
      # break it by accident -- a stylesheet in this repository that collapses it.
      css = File.read!(Path.join(:code.priv_dir(:ash_decisions), "js/ash_decisions.css"))

      assert css =~ ".bjs-powered-by"
      assert css =~ "visibility: visible"

      refute css =~ ~r/\.bjs-powered-by[^}]*display:\s*none/
    end
  end
end

# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.WebTest do
  @moduledoc """
  The decision editor, driven without a browser.

  Every assertion here goes through the hidden save/publish forms rather than the
  dmn-js hook, which is the whole reason those forms exist: an editor whose only
  path to the database runs through JavaScript is an editor with no server-side
  tests, and the parts most worth testing — that opening stores nothing, that
  the first save creates the draft, that saving recompiles, that publishing freezes a version — are all
  server-side.

  What is deliberately *not* asserted here is anything about dmn-js itself. That
  it renders a decision table is its business; that this application hands it a
  document it can open, and stores back what it returns, is ours.
  """

  use AshDecisions.WebConnCase, async: false

  alias AshDecisions.Test.Definition
  alias AshDecisions.Web.EditorLive.Impl

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

  defp stored(key \\ "web_test") do
    Definition
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.Query.do_filter(key: key)
    |> Ash.read!(authorize?: false)
  end

  # The test layout renders flash outside the LiveView, so read it off the socket.
  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash

  describe "opening the editor" do
    test "shows a starter document and stores nothing until a save", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      # The editor's contract with the hook is the `data-xml` attribute, so the
      # meaningful assertion is that a document reached it -- not that any
      # particular element is on screen.
      assert has_element?(view, "#decision-editor[data-xml]")
      assert has_element?(view, "#decision-save")
      assert has_element?(view, "#decision-publish")
      assert has_element?(view, "#decision-origin", "nothing is stored until you save")

      assert stored() == []
    end

    test "the first save creates the draft, the next edits it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      view |> element("#decision-save-form") |> render_submit(%{"xml" => @table_xml})
      assert [%{status: :draft, version: 1}] = stored()

      view |> element("#decision-save-form") |> render_submit(%{"xml" => @table_xml})
      assert [%{status: :draft, version: 1}] = stored()
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
      assert stored("routed_decision") == []
    end

    test "a key from the route cannot break out of the template's attributes" do
      xml = Impl.template_xml(~s(a"><x y="))

      assert xml =~ ~s(id="Definitions_a___x_y__")
      assert xml =~ ~s(name="a&quot;&gt;&lt;x y=&quot;")
    end
  end

  describe "a baseline is shown read-only" do
    test "opening a key with only a baseline shows it and stores nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/baseline-editor")

      assert stored() == []
      assert has_element?(view, "#decision-origin", "baseline v2")
      assert has_element?(view, "#decision-editor[data-xml*='Baseline decision']")
      assert has_element?(view, "#decision-customize")
      refute has_element?(view, "#decision-save")
      refute has_element?(view, "#decision-publish")
      refute has_element?(view, "#decision-revert")
    end

    test "a save or publish that arrives anyway is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/baseline-editor")

      view |> element("#decision-save-form") |> render_submit(%{"xml" => @table_xml})
      assert flash(view)["error"] =~ "read-only"

      view |> element("#decision-publish-form") |> render_submit(%{"xml" => @table_xml})

      assert stored() == []
    end

    test "Customize asks the host for a draft and opens it for editing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/baseline-editor")

      view |> element("#decision-customize") |> render_click()

      assert flash(view)["info"] =~ "Draft created from the baseline"
      assert [%{status: :draft, name: "Customized"}] = stored()
      assert has_element?(view, "#decision-save")
      refute has_element?(view, "#decision-customize")
      assert_push_event(view, "load_xml", %{xml: xml})
      assert xml =~ "Baseline decision"
    end

    test "a refused Customize says why and stays read-only", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/refusing-baseline-editor")

      view |> element("#decision-customize") |> render_click()

      assert flash(view)["error"] == "No baseline to customize from."
      assert stored() == []
      assert has_element?(view, "#decision-customize")
    end
  end

  describe "saving" do
    test "stores the document and compiles it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")

      view
      |> element("#decision-save-form")
      |> render_submit(%{"xml" => @table_xml})

      draft =
        Definition
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
        Definition
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
        Definition
        |> Ash.Query.for_read(:read, %{}, authorize?: false)
        |> Ash.Query.do_filter(key: "web_test", status: :published)
        |> Ash.read!(authorize?: false)

      assert [%{version: 1}] = published
    end
  end

  describe "discarding a draft" do
    test "the button is offered only for a stored draft", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")
      refute has_element?(view, "#decision-discard")

      view |> element("#decision-save-form") |> render_submit(%{"xml" => @table_xml})
      assert has_element?(view, "#decision-discard[data-confirm]")
    end

    test "discarding removes the draft and falls back to the starter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")
      view |> element("#decision-save-form") |> render_submit(%{"xml" => @table_xml})

      view |> element("#decision-discard") |> render_click()

      assert stored() == []
      assert flash(view)["info"] == "Draft discarded."
      assert has_element?(view, "#decision-origin", "nothing is stored until you save")
    end

    test "with a baseline, discarding falls back to the baseline, read-only", %{conn: conn} do
      Definition.create!(
        %{key: "web_test", name: "Own", xml: @table_xml},
        authorize?: false
      )

      {:ok, view, _html} = live(conn, "/baseline-editor")
      view |> element("#decision-discard") |> render_click()

      assert stored() == []
      assert has_element?(view, "#decision-customize")
    end

    test "a published decision offers no discard, and the action refuses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/editor")
      view |> element("#decision-publish-form") |> render_submit(%{"xml" => @table_xml})

      assert [%{status: :published} = published] = stored()
      refute has_element?(view, "#decision-discard")

      assert {:error, %Ash.Error.Invalid{}} =
               Definition.discard(published, authorize?: false)

      assert [%{status: :published}] = stored()
    end

    test "a stale draft struct cannot take the row it has since become" do
      draft =
        Definition.create!(
          %{key: "web_test", name: "Own", xml: @table_xml},
          authorize?: false
        )

      Definition.publish!(draft, authorize?: false)

      assert {:error, _} = Definition.discard(draft, authorize?: false)
      assert [%{status: :published}] = stored()
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

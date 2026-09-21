# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Web.EditorLive.Impl do
  @moduledoc false

  # The server logic behind the editor LiveView that `AshDecisions.Web.EditorLive`
  # injects. It lives here rather than inside the `use` macro's quote so the quote
  # stays readable callbacks and the logic stays ordinary functions; the domain is
  # passed explicitly rather than read from a module attribute.

  require Ash.Query

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias AshDecisions.Dmn.Profile
  alias AshDecisions.Resources
  alias AshDecisions.Scope

  # A new draft has to be a *valid* DMN document, because the create action
  # compiles it: an empty <definitions/> would store a definition whose
  # errors list is populated before the author has done anything wrong.
  #
  # DMN 1.3 rather than 1.5 on purpose. This is the namespace dmn-js reads
  # and writes, and `AshDecisions.Dmn.Profile` normalises it on the way into
  # the engine. Writing 1.5 here would produce a template the editor itself
  # cannot open.
  def template_xml(key) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
                 xmlns:dmndi="https://www.omg.org/spec/DMN/20191111/DMNDI/"
                 xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
                 id="Definitions_#{key}"
                 name="#{key}"
                 namespace="https://github.com/lukegalea/ash_decisions">
      <decision id="Decision_1" name="#{key}">
        <decisionTable id="DecisionTable_1" hitPolicy="FIRST">
          <input id="Input_1" label="Input">
            <inputExpression id="InputExpression_1" typeRef="string">
              <text></text>
            </inputExpression>
          </input>
          <output id="Output_1" label="Output" name="result" typeRef="string"/>
          <rule id="Rule_1">
            <inputEntry id="InputEntry_1"><text></text></inputEntry>
            <outputEntry id="OutputEntry_1"><text>""</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
      <dmndi:DMNDI>
        <dmndi:DMNDiagram id="DMNDiagram_1">
          <dmndi:DMNShape id="DMNShape_Decision_1" dmnElementRef="Decision_1">
            <dc:Bounds height="80" width="180" x="160" y="100"/>
          </dmndi:DMNShape>
        </dmndi:DMNDiagram>
      </dmndi:DMNDI>
    </definitions>
    """
  end

  def resolve_key(params, compile_time_key) do
    params["key"] || params["decision"] || compile_time_key ||
      raise """
      ash_decisions: the editor has no decision key.

      Either pass one at compile time:

          use AshDecisions.Web.EditorLive, domain: MyApp.Decisions, decision: "risk"

      or put it in the route, which is what an application whose tenants author
      their own decisions needs:

          live "/decisions/:key/editor", MyAppWeb.Decisions.EditorLive
      """
  end

  def scope(assigns) do
    Scope.engine(Scope.from_assigns(assigns))
  end

  def load_or_create(socket, domain) do
    {:ok, %{definition: definition_mod}} = Resources.for_domain(domain)

    opts = scope(socket.assigns)
    key = socket.assigns.definition_key

    # `do_filter/2` rather than the filter macro: the resource module is only
    # known at runtime and the macro resolves bare field names statically.
    definition =
      definition_mod
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.do_filter(key: key, status: :draft)
      |> Ash.read_one!(opts)

    definition =
      definition ||
        definition_mod.create!(
          %{
            key: key,
            name: String.capitalize(key) <> " decision",
            xml: template_xml(key)
          },
          Keyword.put(opts, :authorize?, false)
        )

    latest_published =
      case definition_mod.latest_published(key, opts) do
        {:ok, [pub | _]} -> pub
        [pub | _] -> pub
        _ -> nil
      end

    socket
    |> assign(:definition, definition)
    # `to_editable/1`, not the stored text. A baseline written in DMN 1.5 for the engine is
    # one dmn-js cannot parse at all -- it reports `failed to parse document as
    # <dmn:Definitions>` and renders nothing. Storage stays byte-for-byte what the author
    # submitted; each consumer gets the dialect it reads.
    |> assign(:xml, Profile.to_editable(definition.xml))
    |> assign(:errors, definition.errors || [])
    |> assign(:graph, definition.graph)
    |> assign(:latest_published, latest_published)
  end

  def save(socket, xml, domain) do
    {:ok, %{definition: definition_mod}} = Resources.for_domain(domain)

    case definition_mod.save_xml(socket.assigns.definition, xml, scope(socket.assigns)) do
      {:ok, updated} ->
        socket
        |> assign(:definition, updated)
        |> assign(:xml, Profile.to_editable(updated.xml))
        |> assign(:errors, updated.errors || [])
        |> assign(:graph, updated.graph)
        |> assign(:dirty, false)
        |> put_flash(:info, "Saved")

      {:error, error} ->
        socket
        |> assign(:dirty, true)
        |> put_flash(:error, Exception.message(error))
    end
  end

  def publish(socket, domain) do
    {:ok, %{definition: definition_mod}} = Resources.for_domain(domain)

    case definition_mod.publish(socket.assigns.definition, scope(socket.assigns)) do
      {:ok, published} ->
        socket
        |> assign(:definition, published)
        |> assign(:errors, [])
        |> assign(:pending_publish, false)
        |> put_flash(:info, "Published v#{published.version}")

      {:error, error} ->
        socket
        |> assign(:pending_publish, false)
        |> put_flash(:error, Exception.message(error))
    end
  end
end

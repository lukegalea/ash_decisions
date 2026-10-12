# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Web.EditorLive.Impl do
  @moduledoc false

  # The server logic behind the editor LiveView that `AshDecisions.Web.EditorLive`
  # injects. It lives here rather than inside the `use` macro's quote so the quote
  # stays readable callbacks and the logic stays ordinary functions; the domain is
  # passed explicitly rather than read from a module attribute.

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_event: 3]

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
  #
  # The key arrives from the route, so it is escaped for the attributes it lands
  # in and reduced to XML name characters for the id.
  def template_xml(key) do
    name = escape_attribute(key)
    id = String.replace(key, ~r/[^A-Za-z0-9_.-]/u, "_")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/"
                 xmlns:dmndi="https://www.omg.org/spec/DMN/20191111/DMNDI/"
                 xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
                 id="Definitions_#{id}"
                 name="#{name}"
                 namespace="https://github.com/lukegalea/ash_decisions">
      <decision id="Decision_1" name="#{name}">
        <decisionTable id="DecisionTable_1" hitPolicy="FIRST">
          <input id="Input_1" label="Input">
            <inputExpression id="InputExpression_1" typeRef="string">
              <text>input</text>
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

  defp escape_attribute(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
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

  # Reads what exists for the key and shows it. Writes nothing: the draft row is
  # created by the first save. See "Opening the editor writes nothing" in
  # `AshDecisions.Web.EditorLive`.
  def load(socket, domain, baseline_mfa) do
    {:ok, %{definition: definition_mod}} = Resources.for_domain(domain)

    opts = scope(socket.assigns)
    key = socket.assigns.definition_key

    # `do_filter/2` rather than the filter macro: the resource module is only
    # known at runtime and the macro resolves bare field names statically.
    draft =
      definition_mod
      |> Ash.Query.for_read(:read, %{}, opts)
      |> Ash.Query.do_filter(key: key, status: :draft)
      |> Ash.read_one!(opts)

    latest_published =
      case definition_mod.latest_published(key, opts) do
        {:ok, [pub | _]} -> pub
        [pub | _] -> pub
        _ -> nil
      end

    socket =
      socket
      |> assign(:definition, draft)
      |> assign(:latest_published, latest_published)
      |> assign(:baseline, nil)
      |> assign(:read_only, false)

    cond do
      draft ->
        show(socket, :draft, draft.xml, draft.errors, draft.graph)

      # Saving from here starts a draft from what is live, never from a blank
      # template over a real decision.
      latest_published ->
        show(
          socket,
          :published,
          latest_published.xml,
          latest_published.errors,
          latest_published.graph
        )

      found = baseline(baseline_mfa, key, socket) ->
        socket
        |> assign(:baseline, found)
        |> assign(:read_only, true)
        |> show(:baseline, found.xml, [], nil)

      true ->
        show(socket, :template, template_xml(key), [], nil)
    end
  end

  # `to_editable/1`, not the stored text. A baseline written in DMN 1.5 for the engine is
  # one dmn-js cannot parse at all -- it reports `failed to parse document as
  # <dmn:Definitions>` and renders nothing. Storage stays byte-for-byte what the author
  # submitted; each consumer gets the dialect it reads.
  defp show(socket, origin, xml, errors, graph) do
    socket
    |> assign(:origin, origin)
    |> assign(:xml, Profile.to_editable(xml))
    |> assign(:errors, errors || [])
    |> assign(:graph, graph)
  end

  defp baseline(nil, _key, _socket), do: nil

  defp baseline({module, function, args}, key, socket) do
    case apply(module, function, args ++ [key, socket]) do
      %{xml: xml} = found when is_binary(xml) and xml != "" ->
        %{xml: xml, version: Map.get(found, :version), name: Map.get(found, :name)}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def swap("customize", socket, domain, {baseline_mfa, customize_mfa}),
    do: customize(socket, domain, customize_mfa, baseline_mfa)

  def swap("discard", socket, domain, {baseline_mfa, _customize_mfa}),
    do: discard(socket, domain, baseline_mfa)

  # Copying a baseline is the host's act: it knows where baselines live and what
  # lineage to record. The editor asks, then reloads onto the draft that now exists.
  def customize(socket, domain, customize_mfa, baseline_mfa) do
    case run_customize(customize_mfa, socket.assigns.definition_key, socket) do
      :ok ->
        socket = load(socket, domain, baseline_mfa)

        socket
        |> assign(:dirty, false)
        |> put_flash(:info, "Draft created from the baseline. Publish it to switch over.")
        |> push_event("load_xml", %{xml: socket.assigns.xml})

      {:error, message} ->
        put_flash(socket, :error, message)
    end
  end

  defp run_customize(nil, _key, _socket),
    do: {:error, "This baseline cannot be customized from here."}

  defp run_customize({module, function, args}, key, socket) do
    case apply(module, function, args ++ [key, socket]) do
      {:ok, _draft} -> :ok
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      other -> {:error, "Could not customize #{key}: #{inspect(other)}"}
    end
  end

  # A baseline is somebody else's decision. Saving over it would either fail (it is
  # not in this scope) or quietly start a copy with no lineage -- so the only way from
  # here to an editable draft is Customize.
  def save(%{assigns: %{read_only: true}} = socket, _xml, _domain) do
    put_flash(
      socket,
      :error,
      "This is a baseline and is read-only. Customize it to edit a copy of your own."
    )
  end

  def save(socket, xml, domain) do
    {:ok, %{definition: definition_mod}} = Resources.for_domain(domain)
    opts = scope(socket.assigns)

    result =
      case socket.assigns.definition do
        # The first save is what creates the draft -- from the document being
        # saved, so the row never holds anything nobody chose to keep.
        nil ->
          definition_mod.create(
            %{key: socket.assigns.definition_key, name: draft_name(socket.assigns), xml: xml},
            Keyword.put(opts, :authorize?, false)
          )

        definition ->
          definition_mod.save_xml(definition, xml, opts)
      end

    case result do
      {:ok, updated} ->
        socket
        |> assign(:definition, updated)
        |> assign(:origin, :draft)
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

  defp draft_name(%{latest_published: %{name: name}}) when is_binary(name), do: name
  defp draft_name(%{definition_key: key}), do: String.capitalize(key) <> " decision"

  # Abandons the draft and falls back to whatever the key shows without one: the
  # published decision, the baseline, or the template. Same authority as a save --
  # the same actor, through the same scope -- and the action itself refuses
  # anything that is not a draft.
  def discard(%{assigns: %{definition: %{status: :draft} = draft}} = socket, domain, baseline_mfa) do
    {:ok, %{definition: definition_mod}} = Resources.for_domain(domain)

    case definition_mod.discard(draft, scope(socket.assigns)) do
      {:error, error} ->
        put_flash(socket, :error, Exception.message(error))

      _discarded ->
        socket = load(socket, domain, baseline_mfa)

        socket
        |> assign(:dirty, false)
        |> put_flash(:info, "Draft discarded.")
        |> push_event("load_xml", %{xml: socket.assigns.xml})
    end
  end

  def discard(socket, _domain, _baseline_mfa),
    do: put_flash(socket, :error, "There is no draft to discard.")

  # Nothing to publish: a read-only baseline, or a save that did not produce a draft
  # (its flash already says why).
  def publish(%{assigns: %{read_only: true}} = socket, _domain),
    do: assign(socket, :pending_publish, false)

  def publish(%{assigns: %{definition: nil}} = socket, _domain),
    do: assign(socket, :pending_publish, false)

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

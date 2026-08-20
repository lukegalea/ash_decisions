# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Web.EditorLive do
  @moduledoc """
  DMN decision editor LiveView.

  A `use` macro that injects a complete LiveView for editing one decision
  definition, backed by dmn-js: the decision requirements diagram, the decision
  table, and the literal expression editor, which are the three boxed
  expressions `AshDecisions.Compiler` will actually compile.

      defmodule MyAppWeb.Decisions.EditorLive do
        use AshDecisions.Web.EditorLive,
          domain: MyApp.Decisions,
          actor: {MyAppWeb.Decisions.Helpers, :current_actor, []}
      end

  ## Options

    * `:domain` — **required**. The host Ash domain holding the decision resources.
    * `:decision` — the definition key to load or create. Optional: omitted, the
      key comes from the route (`:key` or `:decision`). Supplying neither raises at
      mount with a message saying so, rather than rendering an empty editor.
    * `:actor` — optional `{module, function, args}`, called as
      `module.function(args ++ [socket])`.

  ## The view list is server-rendered, and that is deliberate

  A DMN document is not one diagram: dmn-js models it as a list of views — one
  `drd` for the requirements diagram plus one per decision for its boxed
  expression. dmn-js ships no view switcher of its own; every example builds one.
  Rendering the tabs here means they inherit the application's design system
  instead of introducing a second one inside a single page, at the cost of a round
  trip per switch — which is a switch between views of a document already in the
  browser, so it is cheap and it is not on any hot path.

  ## Testability

  Save and Publish are backed by hidden `<form>` elements, so a test can drive
  the whole lifecycle with `render_submit/2` without a browser or the JS hook.
  The same handlers serve the hook-pushed events in the real flow. This is the
  same arrangement `AshBpmn.Web.DesignerLive` uses, for the same reason: an editor
  whose only path to the database runs through JavaScript is an editor with no
  server-side tests.

  ## Events

  Client → server: `save_xml`, `views_changed`, `dirty_changed`, `import_error`.
  Server → client: `load_xml`, `collect_xml`, `open_view`, `fit`.
  """

  use Phoenix.Component

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    decision_key = Keyword.get(opts, :decision)
    # NOT `Macro.escape/1`. These options arrive already as AST; escaping AST
    # stores the alias unexpanded and it reaches `apply/3` as a three-tuple
    # rather than a module, which fails as `ArgumentError: 2nd argument: not an
    # atom` at the first call. ash_bpmn's LiveViews carry the same note.
    actor_mfa = Keyword.get(opts, :actor, nil)

    quote do
      use Phoenix.LiveView

      require Ash.Query

      @ash_decisions_domain unquote(domain)
      @ash_decisions_key unquote(decision_key)
      @ash_decisions_actor_mfa unquote(actor_mfa)

      # A new draft has to be a *valid* DMN document, because the create action
      # compiles it: an empty <definitions/> would store a definition whose
      # errors list is populated before the author has done anything wrong.
      #
      # DMN 1.3 rather than 1.5 on purpose. This is the namespace dmn-js reads
      # and writes, and `AshDecisions.Dmn.Profile` normalises it on the way into
      # the engine. Writing 1.5 here would produce a template the editor itself
      # cannot open.
      defp ash_decisions_template_xml(key) do
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

      defp ash_decisions_resolve_key(params) do
        params["key"] || params["decision"] || @ash_decisions_key ||
          raise """
          ash_decisions: the editor has no decision key.

          Either pass one at compile time:

              use AshDecisions.Web.EditorLive, domain: MyApp.Decisions, decision: "risk"

          or put it in the route, which is what an application whose tenants author
          their own decisions needs:

              live "/decisions/:key/editor", MyAppWeb.Decisions.EditorLive
          """
      end

      # ── Mount & params ──────────────────────────────────────────────────

      @impl true
      def mount(_params, _session, socket) do
        {:ok,
         assign(socket,
           definition_key: @ash_decisions_key,
           definition: nil,
           xml: "",
           latest_published: nil,
           views: [],
           active_view: nil,
           dirty: false,
           errors: [],
           graph: nil,
           pending_publish: false
         )}
      end

      @impl true
      def handle_params(params, _uri, socket) do
        socket =
          socket
          |> assign(:definition_key, ash_decisions_resolve_key(params))
          |> ash_decisions_load_or_create()

        if connected?(socket) do
          {:noreply, push_event(socket, "load_xml", %{xml: socket.assigns.xml})}
        else
          {:noreply, socket}
        end
      end

      # ── Hook events ─────────────────────────────────────────────────────

      @impl true
      def handle_event("save_xml", %{"xml" => xml}, socket) do
        socket = ash_decisions_save(socket, xml)

        socket =
          if socket.assigns.pending_publish do
            ash_decisions_publish(socket)
          else
            socket
          end

        {:noreply, socket}
      end

      @impl true
      def handle_event("views_changed", %{"views" => views} = params, socket) do
        {:noreply,
         socket
         |> assign(:views, views)
         |> assign(:active_view, params["active"])}
      end

      @impl true
      def handle_event("dirty_changed", %{"dirty" => dirty}, socket) do
        {:noreply, assign(socket, :dirty, dirty)}
      end

      @impl true
      def handle_event("import_error", %{"message" => message}, socket) do
        {:noreply,
         assign(socket, :errors, [
           %{"path" => "xml", "message" => message} | socket.assigns.errors
         ])}
      end

      # ── Buttons ─────────────────────────────────────────────────────────

      @impl true
      def handle_event("collect-xml", _params, socket) do
        {:noreply, push_event(socket, "collect_xml", %{})}
      end

      @impl true
      def handle_event("publish", _params, socket) do
        {:noreply,
         socket
         |> assign(:pending_publish, true)
         |> push_event("collect_xml", %{})}
      end

      @impl true
      def handle_event("open-view", %{"index" => index}, socket) do
        {:noreply, push_event(socket, "open_view", %{index: String.to_integer(index)})}
      end

      @impl true
      def handle_event("revert", _params, socket) do
        socket = ash_decisions_load_or_create(socket)

        {:noreply,
         socket
         |> assign(:dirty, false)
         |> push_event("load_xml", %{xml: socket.assigns.xml})}
      end

      @impl true
      def handle_event("fit", _params, socket) do
        {:noreply, push_event(socket, "fit", %{})}
      end

      # ── Hidden forms: the same lifecycle, without JavaScript ────────────

      @impl true
      def handle_event("save_xml_form", %{"xml" => xml}, socket) do
        {:noreply, ash_decisions_save(socket, xml)}
      end

      @impl true
      def handle_event("publish_form", %{"xml" => xml}, socket) do
        {:noreply, socket |> ash_decisions_save(xml) |> ash_decisions_publish()}
      end

      @impl true
      def render(assigns), do: AshDecisions.Web.EditorLive.__render__(assigns)

      # ── Private ─────────────────────────────────────────────────────────

      defp ash_decisions_scope(socket) do
        AshDecisions.Scope.engine(AshDecisions.Scope.from_assigns(socket.assigns))
      end

      defp ash_decisions_load_or_create(socket) do
        {:ok, %{definition: definition_mod}} =
          AshDecisions.Resources.for_domain(@ash_decisions_domain)

        opts = ash_decisions_scope(socket)
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
                xml: ash_decisions_template_xml(key)
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
        |> assign(:xml, AshDecisions.Dmn.Profile.to_editable(definition.xml))
        |> assign(:errors, definition.errors || [])
        |> assign(:graph, definition.graph)
        |> assign(:latest_published, latest_published)
      end

      defp ash_decisions_save(socket, xml) do
        {:ok, %{definition: definition_mod}} =
          AshDecisions.Resources.for_domain(@ash_decisions_domain)

        case definition_mod.save_xml(
               socket.assigns.definition,
               xml,
               ash_decisions_scope(socket)
             ) do
          {:ok, updated} ->
            socket
            |> assign(:definition, updated)
            |> assign(:xml, AshDecisions.Dmn.Profile.to_editable(updated.xml))
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

      defp ash_decisions_publish(socket) do
        {:ok, %{definition: definition_mod}} =
          AshDecisions.Resources.for_domain(@ash_decisions_domain)

        case definition_mod.publish(socket.assigns.definition, ash_decisions_scope(socket)) do
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
  end

  # ── Rendering ─────────────────────────────────────────────────────────────

  @doc false
  def __render__(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 class="text-lg font-semibold">{@definition_key}</h1>
          <p class="text-sm opacity-70">
            <%= if @definition do %>
              draft v{@definition.version}
            <% end %>
            <%= if @latest_published do %>
              · published v{@latest_published.version}
            <% end %>
            <%= if @dirty do %>
              · <span class="text-warning">unsaved changes</span>
            <% end %>
          </p>
        </div>

        <div class="flex gap-2">
          <button id="decision-fit" class="btn btn-ghost btn-sm" phx-click="fit">Fit</button>
          <button id="decision-revert" class="btn btn-ghost btn-sm" phx-click="revert">
            Revert
          </button>
          <button id="decision-save" class="btn btn-sm" phx-click="collect-xml">Save</button>
          <button id="decision-publish" class="btn btn-primary btn-sm" phx-click="publish">
            Publish
          </button>
        </div>
      </div>

      <%!-- The view tabs. dmn-js has no switcher of its own; see the moduledoc. --%>
      <div :if={@views != []} class="tabs tabs-bordered" id="decision-views">
        <button
          :for={view <- @views}
          type="button"
          class={[
            "tab",
            view["index"] == @active_view && "tab-active"
          ]}
          phx-click="open-view"
          phx-value-index={view["index"]}
        >
          {view["label"]}
          <span :if={view["name"] != ""} class="ml-1 opacity-60">{view["name"]}</span>
        </button>
      </div>

      <%!-- Compile errors, shown rather than swallowed. A DMN document that will
            not compile is the normal state of a document being edited, so this is
            information, not an alarm. --%>
      <ul :if={@errors != []} id="decision-errors" class="rounded-box bg-error/10 p-3 text-sm">
        <li :for={error <- @errors} class="font-mono">
          {error["path"] || error[:path]}: {error["message"] || error[:message]}
        </li>
      </ul>

      <div
        id="decision-editor"
        phx-hook="AshDecisionsEditor"
        phx-update="ignore"
        data-xml={@xml}
        class="rounded-box border border-base-300 bg-base-100"
      >
        <div class="ash-decisions-canvas"></div>
      </div>

      <%!-- Hidden forms. These are the reason this editor has server-side tests
            at all: they give save and publish a path that does not run through
            the browser. See the moduledoc. --%>
      <form id="decision-save-form" phx-submit="save_xml_form" class="hidden">
        <input type="hidden" name="xml" value={@xml} />
      </form>
      <form id="decision-publish-form" phx-submit="publish_form" class="hidden">
        <input type="hidden" name="xml" value={@xml} />
      </form>
    </div>
    """
  end
end

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

      alias AshDecisions.Web.EditorLive

      @ash_decisions_domain unquote(domain)
      @ash_decisions_key unquote(decision_key)
      @ash_decisions_actor_mfa unquote(actor_mfa)

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
          |> assign(:definition_key, EditorLive.Impl.resolve_key(params, @ash_decisions_key))
          |> EditorLive.Impl.load_or_create(@ash_decisions_domain)

        if connected?(socket) do
          {:noreply, push_event(socket, "load_xml", %{xml: socket.assigns.xml})}
        else
          {:noreply, socket}
        end
      end

      # ── Hook events ─────────────────────────────────────────────────────

      @impl true
      def handle_event("save_xml", %{"xml" => xml}, socket) do
        socket = EditorLive.Impl.save(socket, xml, @ash_decisions_domain)

        socket =
          if socket.assigns.pending_publish do
            EditorLive.Impl.publish(socket, @ash_decisions_domain)
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
        socket = socket |> EditorLive.Impl.load_or_create(@ash_decisions_domain)

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
        {:noreply, EditorLive.Impl.save(socket, xml, @ash_decisions_domain)}
      end

      @impl true
      def handle_event("publish_form", %{"xml" => xml}, socket) do
        {:noreply,
         socket
         |> EditorLive.Impl.save(xml, @ash_decisions_domain)
         |> EditorLive.Impl.publish(@ash_decisions_domain)}
      end

      @impl true
      def render(assigns), do: EditorLive.__render__(assigns)
    end
  end

  # ── Rendering ─────────────────────────────────────────────────────────────

  @doc false
  def __render__(assigns) do
    ~H"""
    <%!-- Chrome rides the framework's own vocabulary, not Tailwind/daisyUI
          utilities: framework markup sits outside every host's Tailwind
          content scan, so those classes compile to nothing there and the
          editor rendered browser-bare. The skin ships in
          priv/js/ash_decisions.css (imported by the editor hook), rides the
          --a2ui-* tokens hosts already define, and keeps every id, phx-*
          binding and test selector below untouched. --%>
    <div class="ash-dmn-editor">
      <div class="ash-dmn-header">
        <div>
          <h1>{@definition_key}</h1>
          <p>
            <%= if @definition do %>
              draft v{@definition.version}
            <% end %>
            <%= if @latest_published do %>
              · published v{@latest_published.version}
            <% end %>
            <%= if @dirty do %>
              · <span class="ash-dmn-warning">unsaved changes</span>
            <% end %>
          </p>
        </div>

        <div class="ash-dmn-actions">
          <button id="decision-fit" class="ash-dmn-btn" phx-click="fit">Fit</button>
          <button id="decision-revert" class="ash-dmn-btn" phx-click="revert">
            Revert
          </button>
          <button id="decision-save" class="ash-dmn-btn" phx-click="collect-xml">Save</button>
          <button id="decision-publish" class="ash-dmn-btn ash-dmn-btn--primary" phx-click="publish">
            Publish
          </button>
        </div>
      </div>

      <%!-- The view tabs. dmn-js has no switcher of its own; see the moduledoc. --%>
      <div :if={@views != []} class="ash-dmn-tabs" id="decision-views">
        <button
          :for={view <- @views}
          type="button"
          class={[
            "ash-dmn-tab",
            view["index"] == @active_view && "ash-dmn-tab--active"
          ]}
          phx-click="open-view"
          phx-value-index={view["index"]}
        >
          {view["label"]}
          <span :if={view["name"] != ""} class="ash-dmn-tab-name">{view["name"]}</span>
        </button>
      </div>

      <%!-- Compile errors, shown rather than swallowed. A DMN document that will
            not compile is the normal state of a document being edited, so this is
            information, not an alarm. --%>
      <ul :if={@errors != []} id="decision-errors" class="ash-dmn-errors">
        <li :for={error <- @errors}>
          {error["path"] || error[:path]}: {error["message"] || error[:message]}
        </li>
      </ul>

      <div
        id="decision-editor"
        phx-hook="AshDecisionsEditor"
        phx-update="ignore"
        data-xml={@xml}
        class="ash-dmn-panel"
      >
        <div class="ash-decisions-canvas"></div>
      </div>

      <%!-- Hidden forms. These are the reason this editor has server-side tests
            at all: they give save and publish a path that does not run through
            the browser. See the moduledoc. The HTML `hidden` attribute, not a
            utility class: a host that never compiles Tailwind would render
            these forms visibly. --%>
      <form id="decision-save-form" phx-submit="save_xml_form" hidden>
        <input type="hidden" name="xml" value={@xml} />
      </form>
      <form id="decision-publish-form" phx-submit="publish_form" hidden>
        <input type="hidden" name="xml" value={@xml} />
      </form>
    </div>
    """
  end
end

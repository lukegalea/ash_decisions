# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Web.TryLive do
  @moduledoc """
  Decision trial LiveView: run a version against sample inputs before publishing it.

  A `use` macro that injects a complete LiveView, the companion to
  `AshDecisions.Web.EditorLive`. Pick a version (the draft, or any published or retired one),
  type a value for each input the document declares, and see the answer, which rules matched
  and the hit policy that reduced them. A trial records nothing: see `AshDecisions.Trial`.

      defmodule MyAppWeb.Decisions.TryLive do
        use AshDecisions.Web.TryLive,
          domain: MyApp.Decisions,
          actor: {MyAppWeb.Decisions.Helpers, :current_actor, []},
          gettext: MyAppWeb.Gettext
      end

      live "/decisions/:key/try", MyAppWeb.Decisions.TryLive

  ## Options

    * `:domain` — **required**. The host Ash domain holding the decision resources.
    * `:decision` — the definition key to try. Optional: omitted, the key comes from the
      route (`:key` or `:decision`). Supplying neither raises at the first render with a
      message saying so.
    * `:actor` — optional `{module, function, args}`, called as
      `module.function(args ++ [socket])`. Without it the actor is the socket's
      `:current_user` assign.
    * `:gettext` — optional. The host's Gettext backend; see `AshDecisions.Web.L10n`.

  The tenant is the socket's `:current_tenant` assign, as it is for the editor
  (`AshDecisions.Scope.from_assigns/1`).

  ## Who may try what

  Every read goes through the host's definition read policy, as the actor, in the actor's
  tenant, with no engine bypass. Every event re-reads the chosen version rather than trusting
  an id or a struct held in the socket, so a version the actor may not read, including any
  version of another tenant's decision, is refused the same way a missing one is. There is
  nothing to write, so there are no policies of the package's own to satisfy.

  ## What the host keeps

  The route, the layout around the page, and the link to it from its decision catalogue.
  `mount/3` reads nothing; the versions are read in `handle_params/3`.

  ## Styling

  The page uses the `ash-dmn-*` classes in `priv/js/ash_decisions.css`, which the editor hook
  imports. A host that shows the trial page without loading the editor imports that
  stylesheet itself; it has no dmn-js dependency.

  ## Element ids

  Tests and hosts can rely on these: `#decision-try`, `#decision-try-refused`,
  `#decision-try-version-form`, `#decision-try-version`, `#decision-try-form`,
  `#decision-try-decision`, `#decision-try-input-<name>`, `#decision-try-error-<name>`,
  `#decision-try-compile-errors`, `#decision-try-no-inputs`, `#decision-try-submit`,
  `#decision-try-result`, `#decision-try-outputs`, `#decision-try-rules`,
  `#decision-try-rule-<id>`, `#decision-try-no-rules` and `#decision-try-error`.
  """

  use Phoenix.Component

  import AshDecisions.Web.L10n, only: [t: 2, t: 3]

  alias AshDecisions.Resources
  alias AshDecisions.Trial

  defmacro __using__(opts) do
    domain = Keyword.fetch!(opts, :domain)
    decision_key = Keyword.get(opts, :decision)
    # Not `Macro.escape/1`: these arrive as AST already. See the same note in
    # `AshDecisions.Web.EditorLive`.
    actor_mfa = Keyword.get(opts, :actor, nil)
    gettext = Keyword.get(opts, :gettext, nil)

    quote do
      use Phoenix.LiveView

      alias AshDecisions.Web.TryLive

      @ash_decisions_domain unquote(domain)
      @ash_decisions_key unquote(decision_key)
      @ash_decisions_actor_mfa unquote(actor_mfa)
      @ash_decisions_gettext unquote(gettext)

      @impl true
      def mount(_params, _session, socket),
        do: {:ok, TryLive.__mount__(socket, @ash_decisions_gettext)}

      @impl true
      def handle_params(params, _uri, socket) do
        {:noreply,
         TryLive.__load__(socket, params, {
           @ash_decisions_domain,
           @ash_decisions_key,
           @ash_decisions_actor_mfa
         })}
      end

      @impl true
      def handle_event(event, params, socket) do
        {:noreply,
         TryLive.__event__(
           event,
           params,
           socket,
           {@ash_decisions_domain, @ash_decisions_actor_mfa}
         )}
      end

      @impl true
      def render(assigns), do: TryLive.__render__(assigns)
    end
  end

  # ── Server logic ──────────────────────────────────────────────────────────

  @doc false
  def __mount__(socket, gettext) do
    assign(socket,
      gettext: gettext,
      key: nil,
      versions: [],
      selected: nil,
      decision_names: [],
      decision: nil,
      declared: [],
      raw: %{},
      field_errors: %{},
      outcome: nil
    )
  end

  @doc false
  def __load__(socket, params, {domain, compile_time_key, actor_mfa}) do
    key = resolve_key(params, compile_time_key)
    gettext = socket.assigns.gettext
    socket = assign(socket, key: key, page_title: t(gettext, "Try %{key}", key: key))
    versions = Trial.versions(definition(domain), key, read_opts(socket, actor_mfa))

    socket
    |> assign(:versions, versions)
    |> select(versions |> default_version() |> maybe_id(), {domain, actor_mfa})
  end

  @doc false
  def __event__("select_version", %{"version" => id}, socket, config),
    do: select(socket, id, config)

  def __event__("select_decision", %{"decision" => name}, socket, _config),
    do: assign(socket, decision: name, outcome: nil)

  def __event__("try", params, socket, config) do
    case fresh(socket, params["version"], config) do
      nil ->
        assign(socket, :outcome, {:refused, nil})

      definition ->
        raw = Map.get(params, "inputs", %{})

        socket
        |> assign(raw: raw, selected: definition)
        |> run(definition, raw)
    end
  end

  def __event__(_event, _params, socket, _config), do: socket

  defp resolve_key(params, compile_time_key) do
    params["key"] || params["decision"] || compile_time_key ||
      raise """
      ash_decisions: the trial page has no decision key.

      Either pass one at compile time:

          use AshDecisions.Web.TryLive, domain: MyApp.Decisions, decision: "risk"

      or put it in the route:

          live "/decisions/:key/try", MyAppWeb.Decisions.TryLive
      """
  end

  defp definition(domain) do
    {:ok, %{definition: definition}} = Resources.for_domain(domain)
    definition
  end

  defp read_opts(socket, actor_mfa),
    do: [actor: actor(socket, actor_mfa), tenant: socket.assigns[:current_tenant]]

  defp actor(socket, nil), do: socket.assigns[:current_user]

  defp actor(socket, {module, function, args}),
    do: apply(module, function, args ++ [socket])

  defp run(socket, definition, raw) do
    declared = Trial.inputs(definition)

    case Trial.cast(declared, raw) do
      {:error, errors} ->
        assign(socket, field_errors: errors, outcome: nil)

      {:ok, inputs} ->
        assign(socket,
          field_errors: %{},
          outcome: Trial.run(definition, inputs, socket.assigns.decision)
        )
    end
  end

  defp select(socket, nil, _config), do: assign(socket, :selected, nil)

  defp select(socket, id, config) do
    case fresh(socket, id, config) do
      nil ->
        assign(socket, :selected, nil)

      definition ->
        names = Trial.decisions(definition)

        assign(socket,
          selected: definition,
          decision_names: names,
          decision: List.first(names),
          declared: Trial.inputs(definition),
          raw: %{},
          field_errors: %{},
          outcome: nil
        )
    end
  end

  defp fresh(socket, id, {domain, actor_mfa}) when is_binary(id),
    do: Trial.version(definition(domain), socket.assigns.key, id, read_opts(socket, actor_mfa))

  defp fresh(_socket, _id, _config), do: nil

  # The draft is the thing someone is about to publish, so it is what they most want to try.
  defp default_version(versions),
    do: Enum.find(versions, &(&1.status == :draft)) || List.first(versions)

  defp maybe_id(nil), do: nil
  defp maybe_id(definition), do: definition.id

  # ── Words ─────────────────────────────────────────────────────────────────

  defp version_label(gettext, definition) do
    t(gettext, "v%{version} (%{status})",
      version: definition.version,
      status: status_label(gettext, definition.status)
    )
  end

  defp status_label(gettext, :draft), do: t(gettext, "draft")
  defp status_label(gettext, :published), do: t(gettext, "published")
  defp status_label(gettext, :retired), do: t(gettext, "retired")
  defp status_label(_gettext, other), do: to_string(other)

  defp field_error(gettext, :blank), do: t(gettext, "Enter a value.")
  defp field_error(gettext, :not_a_number), do: t(gettext, "Enter a number, like 42 or 3.5.")
  defp field_error(gettext, :not_a_boolean), do: t(gettext, "Enter true or false.")
  defp field_error(gettext, :not_a_date), do: t(gettext, "Enter a date as YYYY-MM-DD.")

  defp engine_error(gettext, {:evaluation_timeout, _ms}),
    do: t(gettext, "The decision took too long to evaluate.")

  defp engine_error(gettext, {:no_decisions, _key}),
    do: t(gettext, "This version has no decision to evaluate. Fix it in the editor first.")

  defp engine_error(gettext, {:ambiguous_decision, _key, _names}),
    do: t(gettext, "Choose which decision to evaluate.")

  defp engine_error(gettext, {load, _reason})
       when load in [:model_load_failed, :model_load_raised],
       do: t(gettext, "This version could not be loaded. Fix it in the editor first.")

  defp engine_error(gettext, reason) do
    t(gettext, "The decision could not be evaluated: %{reason}",
      reason: inspect(reason, limit: 8, printable_limit: 200)
    )
  end

  defp format_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value, limit: 20, printable_limit: 200)

  # ── Rendering ─────────────────────────────────────────────────────────────

  @doc false
  def __render__(assigns) do
    ~H"""
    <%!-- The same token-driven `ash-dmn-*` vocabulary as the editor, for the same reason:
          framework markup sits outside every host's Tailwind content scan. --%>
    <div class="ash-dmn-editor ash-dmn-trial" id="decision-try">
      <div class="ash-dmn-header">
        <div>
          <h1>{t(@gettext, "Try %{key}", key: @key)}</h1>
          <p>
            {t(
              @gettext,
              "Run a version against sample inputs. Nothing is recorded: a trial is not a decision about a case."
            )}
          </p>
        </div>
      </div>

      <p :if={@versions == [] or @outcome == {:refused, nil}} id="decision-try-refused">
        {t(@gettext, "There is no version of this decision that you can try.")}
      </p>

      <div :if={@versions != []} class="ash-dmn-trial-body">
        <form id="decision-try-version-form" phx-change="select_version" class="ash-dmn-field">
          <label for="decision-try-version">{t(@gettext, "Version")}</label>
          <select id="decision-try-version" name="version" class="ash-dmn-input">
            <option :for={v <- @versions} value={v.id} selected={@selected && @selected.id == v.id}>
              {version_label(@gettext, v)}
            </option>
          </select>
        </form>

        <form
          :if={@selected}
          id="decision-try-form"
          phx-submit="try"
          phx-change="select_decision"
          class="ash-dmn-trial-form"
        >
          <input type="hidden" name="version" value={@selected.id} />

          <div :if={length(@decision_names) > 1} class="ash-dmn-field">
            <label for="decision-try-decision">{t(@gettext, "Decision")}</label>
            <select id="decision-try-decision" name="decision" class="ash-dmn-input">
              <option :for={name <- @decision_names} value={name} selected={name == @decision}>
                {name}
              </option>
            </select>
          </div>

          <p
            :if={@selected.errors not in [nil, []]}
            id="decision-try-compile-errors"
            class="ash-dmn-error-text"
          >
            {t(
              @gettext,
              "This version has errors and cannot be tried until they are fixed in the editor."
            )}
          </p>

          <p :if={@declared == [] and @selected.errors in [nil, []]} id="decision-try-no-inputs">
            {t(@gettext, "This decision declares no inputs.")}
          </p>

          <div :for={input <- @declared} class="ash-dmn-field">
            <label for={"decision-try-input-#{input.name}"}>
              {input.name}
              <span :if={input.type} class="ash-dmn-type">{input.type}</span>
            </label>
            <input
              id={"decision-try-input-#{input.name}"}
              type="text"
              name={"inputs[#{input.name}]"}
              value={@raw[input.name]}
              class="ash-dmn-input"
            />
            <p
              :if={@field_errors[input.name]}
              id={"decision-try-error-#{input.name}"}
              class="ash-dmn-error-text"
            >
              {field_error(@gettext, @field_errors[input.name])}
            </p>
          </div>

          <div class="ash-dmn-actions">
            <button id="decision-try-submit" type="submit" class="ash-dmn-btn ash-dmn-btn--primary">
              {t(@gettext, "Try it")}
            </button>
          </div>
        </form>

        <div :if={match?({:ok, _}, @outcome)} id="decision-try-result" class="ash-dmn-panel ash-dmn-trial-result">
          <% {:ok, result} = @outcome %>
          <h2>{t(@gettext, "Result")}</h2>
          <p id="decision-try-outputs" class="ash-dmn-mono">{format_value(result.outputs)}</p>
          <p class="ash-dmn-muted">
            {t(@gettext, "Decision %{decision}, version %{version}",
              decision: result.decision,
              version: result.definition_version
            )}
            <span :if={result.hit_policy}>
              {t(@gettext, "hit policy %{policy}", policy: result.hit_policy)}
            </span>
          </p>
          <h3>{t(@gettext, "Rules that matched")}</h3>
          <p :if={result.matched_rules == []} id="decision-try-no-rules">
            {t(@gettext, "No rule matched.")}
          </p>
          <ul id="decision-try-rules">
            <li :for={rule <- result.matched_rules} id={"decision-try-rule-#{rule.id}"}>
              <span :if={rule.position}>{t(@gettext, "Rule %{position}", position: rule.position)}</span>
              <span class="ash-dmn-mono">{rule.id}</span>
              <span :if={rule.description}>{rule.description}</span>
            </li>
          </ul>
        </div>

        <p :if={match?({:error, _}, @outcome)} id="decision-try-error" class="ash-dmn-error-text">
          <% {:error, reason} = @outcome %>
          {engine_error(@gettext, reason)}
        </p>
      </div>
    </div>
    """
  end
end

# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

# IMPORTANT: definition order is compilation order here. The wrapper LiveView
# must exist before the Router that routes to it, and the Router before the
# Endpoint that plugs it.

defmodule AshDecisions.Web.TestLayout do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <title>AshDecisions Test</title>
      </head>
      <body>
        <div id="flash-group">
          <div :for={{_key, message} <- @flash}>{message}</div>
        </div>
        <main>{@inner_content}</main>
      </body>
    </html>
    """
  end
end

defmodule AshDecisions.Web.EditorWrapper do
  @moduledoc false

  use AshDecisions.Web.EditorLive,
    domain: AshDecisions.Test.Domain,
    decision: "web_test"
end

defmodule AshDecisions.Web.TestRouter do
  @moduledoc false

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AshDecisions.Web.TestLayout, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", AshDecisions.Web do
    pipe_through(:browser)

    live("/editor", EditorWrapper, :index, as: :editor)
    live("/decisions/:key/editor", EditorWrapper, :show, as: :keyed_editor)
  end
end

defmodule AshDecisions.Web.TestPubSub do
  @moduledoc false
end

defmodule AshDecisions.Web.TestEndpoint do
  @moduledoc false

  # Configuration lives in `config/test.exs`, NOT in a compile-time
  # `Application.put_env` in this module body. That trick only runs on a fresh
  # compilation and is silently absent when the test suite starts from cached
  # beams, presenting as "the signing salt is missing or too short" -- which
  # names the salt and says nothing about why it disappeared. ash_bpmn's
  # config/test.exs carries the same note for the same reason.
  use Phoenix.Endpoint, otp_app: :ash_decisions

  socket("/live", Phoenix.LiveView.Socket)

  plug(Plug.RequestId)

  plug(Plug.Session,
    store: :cookie,
    key: "_ash_decisions_test_session",
    signing_salt: String.duplicate("c", 16),
    encrypt: false
  )

  plug(AshDecisions.Web.TestRouter)
end

defmodule AshDecisions.ErrorView do
  @moduledoc false
  def render(template, _assigns), do: "error: #{template}"
end

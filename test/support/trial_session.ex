# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Test.TrialSession do
  @moduledoc """
  What a host's `on_mount` does for the decision LiveViews: assigns `:current_user` and
  `:current_tenant` from the session, and puts the request's locale on the process.
  """

  def on_mount(:default, _params, session, socket) do
    if locale = session["locale"], do: Gettext.put_locale(AshDecisions.Test.Gettext, locale)

    {:cont,
     Phoenix.Component.assign(socket,
       current_user: session["actor"],
       current_tenant: session["tenant"]
     )}
  end

  @doc "The actor resolver a host passes as `actor:`."
  def current_actor(socket), do: socket.assigns[:current_user]
end

# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.WebConnCase do
  @moduledoc """
  Case template for the decision editor's LiveView tests.

  Starts the test PubSub and endpoint under the test supervisor and checks out
  the SQL sandbox. The repo itself is started once in `test_helper.exs`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint AshDecisions.Web.TestEndpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(AshDecisions.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    start_supervised!(
      {Phoenix.PubSub, name: AshDecisions.Web.TestPubSub, adapter: Phoenix.PubSub.PG2}
    )

    start_supervised!(AshDecisions.Web.TestEndpoint)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end

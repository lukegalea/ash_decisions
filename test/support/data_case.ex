# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.DataCase do
  @moduledoc """
  Case template for tests that talk to a real PostgreSQL server.

  Each test runs inside the Ecto SQL sandbox with automatic checkout/return.
  """

  use ExUnit.CaseTemplate

  alias AshDecisions.TestRepo
  alias Ecto.Adapters.SQL

  using do
    quote do
      import AshDecisions.DataCase
      alias AshDecisions.TestRepo
    end
  end

  setup tags do
    pid = SQL.Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end

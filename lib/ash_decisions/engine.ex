# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Engine do
  @moduledoc """
  Loads the decision engine's code before an evaluation's time limit starts.

  `AshDecisions.Evaluator` and `AshDecisions.Feel` run the engine in a task they kill when its
  time is up. That limit is for what an author wrote, not for how the VM finds code. In
  embedded mode (a release) every module is loaded at boot, so the two are the same. In
  interactive mode (`mix test`, `iex -S mix`) a module loads on first call, through the node's
  one code server. A busy test suite queues every process's loads there, and an evaluation that
  reached a module nobody had called yet waited in that queue past its limit:
  `{:evaluation_timeout, 1000}` from a decision that takes microseconds.

  So both call `preload/0` before they start the clock. The first call loads every module of
  this package and of the engine's applications (`applications/0`); later calls read one
  `:persistent_term` and return. A host may also call it at boot or in its `test_helper.exs`,
  to pay the load before its first request rather than inside it; it never has to.

  The engine's applications are found, not listed: `boxic_dmn`, `boxic_feel` and everything
  they declare in their `.app` files, transitively, so a dependency the engine adds later is
  loaded too. The language runtime (`kernel`, `stdlib`, `elixir`, `compiler`, `logger`) is left
  out: every program starts on it, and loading all of it would load the compiler.
  """

  @engine [:boxic_dmn, :boxic_feel]
  @runtime [:kernel, :stdlib, :elixir, :compiler, :logger]
  @loaded {__MODULE__, :loaded}

  @doc """
  Loads the engine's code, once per VM. Cheap after the first call.
  """
  @spec preload() :: :ok
  def preload do
    if :persistent_term.get(@loaded, false) do
      :ok
    else
      for app <- [:ash_decisions | applications()],
          modules = Application.spec(app, :modules) || [],
          do: :ok = :code.ensure_modules_loaded(modules)

      :persistent_term.put(@loaded, true)
    end
  end

  @doc """
  The applications whose code an evaluation runs: the engine's and everything they depend on,
  less the language runtime. Applications that are not loaded (an optional dependency nobody
  added) are skipped.
  """
  @spec applications() :: [atom()]
  def applications do
    @engine
    |> walk(@runtime)
    |> Enum.reject(&(&1 in @runtime))
    |> Enum.filter(&Application.spec(&1, :vsn))
    |> Enum.sort()
  end

  # A handful of applications, so a list is the set.
  defp walk([], seen), do: seen

  defp walk([app | rest], seen) do
    if app in seen do
      walk(rest, seen)
    else
      deps =
        (Application.spec(app, :applications) || []) ++
          (Application.spec(app, :included_applications) || [])

      walk(deps ++ rest, [app | seen])
    end
  end
end

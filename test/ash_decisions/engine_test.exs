# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.EngineTest do
  @moduledoc """
  The engine's code loads before an evaluation's time limit starts, so a module's first load in
  interactive mode is not counted against the decision.
  """

  # Unloads a module and resets a VM-wide `:persistent_term` flag: both are global to the node.
  use ExUnit.Case, async: false

  alias AshDecisions.{Engine, Evaluator, Feel}

  @discount File.read!("test/fixtures/discount.dmn")

  # A module of the engine's applications that no evaluation calls (it parses IANA source
  # files when tz rebuilds its database), so only `Engine.preload/0` can load it back.
  @untouched Tz.IanaFileParser

  setup do
    unload(@untouched)
    :persistent_term.erase({Engine, :loaded})
    on_exit(fn -> Engine.preload() end)
    :ok
  end

  test "the engine's applications are found from its dependencies, without the runtime" do
    apps = Engine.applications()

    for app <- [:boxic_dmn, :boxic_feel, :decimal, :tz], do: assert(app in apps)
    for app <- [:kernel, :stdlib, :elixir, :compiler, :logger], do: refute(app in apps)
  end

  test "preload/0 loads every module of this package and of the engine's applications" do
    refute :code.is_loaded(@untouched)

    assert :ok = Engine.preload()

    for app <- [:ash_decisions | Engine.applications()],
        module <- Application.spec(app, :modules) || [],
        do: assert(:code.is_loaded(module), "#{inspect(module)} (#{app}) is not loaded")
  end

  test "an evaluation loads the engine before its clock starts" do
    Evaluator.flush_cache(:all)

    # A zero limit kills the engine's task before it does any work, so the module is back only
    # if it was loaded in the caller before the task started.
    _ =
      Evaluator.evaluate(definition(@discount), %{"orderTotal" => 500}, record: false, timeout: 0)

    assert :code.is_loaded(@untouched)
  end

  test "a FEEL expression loads the engine before its clock starts" do
    _ = Feel.evaluate("1 + 1", %{}, timeout: 0)

    assert :code.is_loaded(@untouched)
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  defp definition(xml) do
    %{
      id: nil,
      key: "engine-#{System.unique_integer([:positive])}",
      version: 1,
      xml: xml,
      content_hash: :sha256 |> :crypto.hash(xml) |> Base.encode16(case: :lower),
      graph: AshDecisions.Compiler.compile!(xml)
    }
  end
end

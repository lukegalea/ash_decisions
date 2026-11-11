# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.JsHooksTest do
  @moduledoc """
  `priv/js/hooks.js` is the contract between this package's LiveView hooks and
  the hosts that register them: for each hook it must name every event the hook
  handles, and point `load` at the file that defines it. A host that loads a
  hook lazily subscribes to `events` before the code arrives, so a name missing
  here is a server push nobody hears. The hook sources are ground truth; this
  test reads both with regexes, the same tier Keystone's drift test uses.
  """

  use ExUnit.Case, async: true

  @js_dir Path.join(Path.dirname(__DIR__), "priv/js")
  @hooks_path Path.join(@js_dir, "hooks.js")

  # One entry of the exported `hooks` object: the registered name, the events
  # list, and the module path the `load` thunk imports.
  @entry ~r/(\w+):\s*\{[^{}]*?events:\s*\[([^\]]*)\][^{}]*?import\s*\(\s*["']([^"']+)["']\s*\)/s
  @const ~r/const\s+([A-Za-z$_][\w$]*)\s*=\s*(?:"([^"]*)"|'([^']*)')\s*;?/
  @call ~r/handleEvent\s*\(\s*([^,)]*)/

  test "hooks.js has no top-level imports" do
    source = hooks_source()

    refute source =~ ~r/^import\s/m,
           "hooks.js must not import at the top level: hosts include it on " <>
             "every page, and an import pulls a hook's dependencies with it"
  end

  test "every `load` points at a file that exists" do
    for {_name, import_path} <- entries() do
      path = hook_source_path(import_path)

      assert File.regular?(path),
             "`load` imports #{inspect(import_path)}, which does not exist at #{path}"
    end
  end

  test "each hook's `events` names exactly the events its source handles" do
    for {name, import_path} <- entries() do
      source = import_path |> hook_source_path() |> File.read!() |> strip_comments()
      events = events_by_entry() |> Map.fetch!(name)
      {handled, unknown} = handled_events(source)

      assert unknown == [],
             "#{name}: handleEvent called with a name that is neither a string " <>
               "literal nor a known constant: #{inspect(unknown)}; teach this " <>
               "test to read it"

      missing = Enum.sort(handled -- events)
      extra = Enum.sort(events -- handled)

      assert {missing, extra} == {[], []},
             "#{name}: handles #{inspect(missing)} that its `events` list does " <>
               "not name, and names #{inspect(extra)} that it never handles"
    end
  end

  defp hooks_source, do: File.read!(@hooks_path)

  # The hook entries of `priv/js/hooks.js`, in declaration order.
  defp entries do
    found = Regex.scan(@entry, hooks_source())
    assert found != [], "no hook entries found in #{@hooks_path}"

    Enum.map(found, fn [_all, name, _events, import_path] ->
      {name, import_path}
    end)
  end

  defp events_by_entry do
    found = Regex.scan(@entry, hooks_source())

    Map.new(found, fn [_all, name, events_inner, _import_path] ->
      events =
        events_inner
        |> String.split(",")
        |> Enum.map(&strip_token/1)
        |> Enum.reject(&(&1 == ""))

      {name, events}
    end)
  end

  # Events a hook handles: the string literals passed to `handleEvent`, plus
  # the values of the constants passed to it (`handleEvent(CONST` where
  # `const CONST = "name"`). A name that is neither is reported as unknown.
  defp handled_events(code) do
    consts = constants(code)

    {events, unknown} =
      Regex.scan(@call, code)
      |> Enum.map(fn [_all, arg] -> classify(arg, consts) end)
      |> Enum.split_with(fn
        {:event, _} -> true
        {:unknown, _} -> false
      end)

    {Enum.map(events, fn {:event, event} -> event end),
     Enum.map(unknown, fn {:unknown, arg} -> arg end)}
  end

  defp constants(code) do
    # Regex.scan omits groups that did not participate: only one of the two
    # quoting branches ever matches, so each row is [all, name, value].
    Regex.scan(@const, code)
    |> Map.new(fn [_all, name, value] -> {name, value} end)
  end

  defp classify(arg, consts) do
    arg = String.trim(arg)

    cond do
      quoted?(arg) -> {:event, String.slice(arg, 1, byte_size(arg) - 2)}
      Map.has_key?(consts, arg) -> {:event, Map.fetch!(consts, arg)}
      true -> {:unknown, arg}
    end
  end

  defp quoted?(arg) do
    byte_size(arg) >= 2 and
      ((String.starts_with?(arg, ~s(")) and String.ends_with?(arg, ~s("))) or
         (String.starts_with?(arg, "'") and String.ends_with?(arg, "'")))
  end

  defp strip_comments(source) do
    source
    |> String.replace(~r|/\*.*?\*/|s, "")
    |> String.replace(~r|//[^\n]*|, "")
  end

  # `'load_xml'` -> `load_xml`, dropping any trailing line comment. Strip the
  # wrapping pair of quotes by hand: this Elixir's String.trim/2 ignores
  # multi-character trim sets (single characters work), so `"'` would not trim.
  defp strip_token(token) do
    token = token |> String.split("//", parts: 2) |> List.first() |> String.trim()

    case {String.first(token), String.last(token)} do
      {q, q} when q in ["\"", "'"] -> String.slice(token, 1, byte_size(token) - 2)
      _ -> token
    end
  end

  # The import path in `hooks.js` is relative to `priv/js`, like every import
  # of a sibling module.
  defp hook_source_path(import_path), do: Path.expand(import_path, @js_dir)
end

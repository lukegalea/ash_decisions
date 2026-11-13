# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Web.L10n do
  @moduledoc """
  The text the package's LiveViews write for a reader, in the host's language.

  `AshDecisions.Web.EditorLive` and `AshDecisions.Web.TryLive` take a `gettext:` option: the
  host's Gettext backend. With it, every message is looked up with `Gettext.dgettext/4` in the
  `"ash_decisions"` domain, in the locale the host has already put on the LiveView process
  (`Gettext.put_locale/1,2`, usually in an `on_mount` hook). Without it, the English msgid is
  shown with its `%{key}` placeholders filled in.

  The messages ship in `priv/gettext/ash_decisions.pot`. A host copies that template into its
  own `priv/gettext/` and runs `mix gettext.merge priv/gettext` to get a `.po` per locale;
  `mix gettext.extract` does not read dependencies, so the template is how the msgids reach
  the host.

  This package does not depend on `:gettext`. The backend is the host's, and Gettext is
  called only when a host configures one.
  """

  @domain "ash_decisions"
  @placeholder ~r/%\{(\w+)\}/

  @doc "The Gettext domain the package's messages live in."
  @spec domain() :: String.t()
  def domain, do: @domain

  @doc """
  `msgid` in the host's language, or in English when `backend` is `nil`.

  `bindings` fill the message's `%{key}` placeholders, as Gettext interpolates them. Each is
  replaced once, so a value that itself contains `%{...}` is never interpolated again.
  """
  @spec t(module() | nil, String.t(), keyword() | map()) :: String.t()
  def t(backend, msgid, bindings \\ [])

  def t(nil, msgid, bindings), do: interpolate(msgid, Map.new(bindings))

  def t(backend, msgid, bindings) when is_atom(backend) do
    # Resolved at runtime: the host has the :gettext dependency, this package does not.
    Module.concat(["Gettext"]).dgettext(backend, @domain, msgid, Map.new(bindings))
  end

  defp interpolate(msgid, bindings) when map_size(bindings) == 0, do: msgid

  defp interpolate(msgid, bindings) do
    values = Map.new(bindings, fn {name, value} -> {to_string(name), value} end)

    Regex.replace(@placeholder, msgid, fn whole, key ->
      values |> Map.get(key, whole) |> to_string()
    end)
  end
end

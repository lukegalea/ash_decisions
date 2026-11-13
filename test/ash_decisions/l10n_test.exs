# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.L10nTest do
  @moduledoc """
  `AshDecisions.Web.L10n`, and the template it promises hosts: every message the LiveViews
  write is in `priv/gettext/ash_decisions.pot`, and nothing in it is stale.
  """

  use ExUnit.Case, async: false

  alias AshDecisions.Web.L10n

  @sources [
    "lib/ash_decisions/web/editor_live.ex",
    "lib/ash_decisions/web/editor_live/impl.ex",
    "lib/ash_decisions/web/try_live.ex"
  ]

  # `t(<backend>, "msgid"` as the LiveViews spell it.
  @call ~r/\bt\(\s*(?:@gettext|gettext\(socket\)|gettext)\s*,\s*"((?:[^"\\]|\\.)*)"/s

  describe "t/3 without a backend" do
    test "is the msgid, with its placeholders filled once" do
      assert L10n.t(nil, "Saved") == "Saved"
      assert L10n.t(nil, "Try %{key}", key: "risk") == "Try risk"
      assert L10n.t(nil, "Try %{key}", key: "%{key}") == "Try %{key}"
      assert L10n.t(nil, "Rule %{position}", %{position: 2}) == "Rule 2"
      assert L10n.t(nil, "Try %{key}", other: "x") == "Try %{key}"
    end
  end

  describe "t/3 with a backend" do
    test "translates in the process's locale, and falls back to the msgid" do
      Gettext.put_locale(AshDecisions.Test.Gettext, "fr")

      assert L10n.t(AshDecisions.Test.Gettext, "Try %{key}", key: "risk") == "Essayer risk"
      assert L10n.t(AshDecisions.Test.Gettext, "No rule matched.") == "No rule matched."
    after
      Gettext.put_locale(AshDecisions.Test.Gettext, "en")
    end
  end

  test "the shipped template holds exactly the messages the LiveViews write" do
    used =
      for path <- @sources,
          [_, msgid] <- Regex.scan(@call, File.read!(path)),
          into: MapSet.new(),
          do: msgid

    shipped =
      "priv/gettext/ash_decisions.pot"
      |> Expo.PO.parse_file!()
      |> Map.fetch!(:messages)
      |> MapSet.new(&IO.iodata_to_binary(&1.msgid))

    assert MapSet.difference(used, shipped) == MapSet.new(), "missing from the .pot"
    assert MapSet.difference(shipped, used) == MapSet.new(), "stale in the .pot"
  end

  test "every t/2,3 call in the LiveViews is one the template check can read" do
    for path <- @sources do
      source = File.read!(path)
      calls = Regex.scan(~r/\bt\(/, source) |> length()
      readable = Regex.scan(@call, source) |> length()

      assert calls == readable, "#{path}: a t/2,3 call whose msgid the template check misses"
    end
  end
end

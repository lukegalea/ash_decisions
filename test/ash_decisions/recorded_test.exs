# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.RecordedTest do
  @moduledoc """
  `AshDecisions.Recorded`: what an `Evaluation` row stores, and the readings a replay tries.
  """

  use ExUnit.Case, async: true

  alias AshDecisions.Recorded

  describe "encode/1" do
    test "writes what a person can read, and nothing that loses precision" do
      assert Recorded.encode(%{
               amount: Decimal.new("12.50"),
               due: ~D[2026-01-15],
               at: ~U[2026-01-15 10:00:00Z],
               local: ~N[2026-01-15 10:00:00],
               time: ~T[10:00:00],
               tier: :gold,
               ok: true,
               tags: [:a, 1]
             }) == %{
               "amount" => "12.50",
               "due" => "2026-01-15",
               "at" => "2026-01-15T10:00:00Z",
               "local" => "2026-01-15T10:00:00",
               "time" => "10:00:00",
               "tier" => "gold",
               "ok" => true,
               "tags" => ["a", 1]
             }
    end
  end

  describe "readings/2" do
    @declared [
      %{name: "amount", type: "number"},
      %{name: "due", type: "date"},
      %{name: "at", type: "dateTime"},
      %{name: "ok", type: "boolean"},
      %{name: "tier", type: "string"}
    ]

    test "revives by the declared type first, and keeps the stored map as the fallback" do
      stored = %{"amount" => "12.5", "due" => "2026-01-15", "at" => "2026-01-15T10:00:00Z", "ok" => "true", "tier" => "gold"}

      assert [typed, ^stored] = Recorded.readings(stored, @declared)

      assert typed == %{
               "amount" => Decimal.new("12.5"),
               "due" => ~D[2026-01-15],
               "at" => ~U[2026-01-15 10:00:00Z],
               "ok" => true,
               "tier" => "gold"
             }
    end

    test "rows written before ISO 8601 dates still revive" do
      stored = %{"due" => "~D[2026-01-15]", "at" => "~U[2026-01-15 10:00:00Z]"}

      assert [%{"due" => ~D[2026-01-15], "at" => ~U[2026-01-15 10:00:00Z]}, ^stored] =
               Recorded.readings(stored, @declared)
    end

    test "a value that does not read as its type is left as stored, once" do
      stored = %{"amount" => "lots", "tier" => "gold"}
      assert Recorded.readings(stored, @declared) == [stored]
    end

    test "an undeclared input is passed through" do
      assert Recorded.readings(%{"extra" => "1"}, @declared) == [%{"extra" => "1"}]
    end
  end
end

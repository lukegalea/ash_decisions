# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Recorded do
  @moduledoc """
  How a value the engine saw is written onto an `Evaluation` row, and read back.

  An `Evaluation` stores its inputs and outputs as JSON, so whatever the engine was handed
  has to survive a jsonb round trip. `encode/1` is that one-way step: decimals become their
  exact decimal string rather than a float, dates and times their ISO 8601 text, atoms their
  name. The row is evidence a person reads, so it is written in a form a person can read.

  The step loses the type. `"12.5"` on a row may have been the decimal 12.5 or the string
  `"12.5"`, and the engine treats the two differently: some hosts hand the engine decimals,
  and some (a bridge that flattens answers to decimal strings) hand it strings on purpose.
  `readings/2` therefore offers both: the values revived by the type the version declares for
  each input, and the values exactly as stored. `AshDecisions.Replay` keeps whichever reading
  reproduces what the row recorded, and never guesses between them.
  """

  @doc """
  A value as it is written onto an `Evaluation` row: plain JSON data.
  """
  @spec encode(term()) :: term()
  def encode(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def encode(%Date{} = value), do: Date.to_iso8601(value)
  def encode(%Time{} = value), do: Time.to_iso8601(value)
  def encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encode(%Duration{} = value), do: Duration.to_iso8601(value)
  def encode(%{__struct__: _} = value), do: inspect(value)
  def encode(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), encode(v)} end)
  def encode(list) when is_list(list), do: Enum.map(list, &encode/1)
  def encode(value) when is_atom(value) and not is_boolean(value), do: to_string(value)
  def encode(value), do: value

  @doc """
  The ways to read recorded `inputs` back into engine values, most faithful first, without
  duplicates.

  `declared` is the version's inputs as `AshDecisions.Trial.inputs/1` lists them: each a name
  and the FEEL type the author gave it. The first reading revives each declared input by that
  type; the last is the stored map untouched.
  """
  @spec readings(map(), [%{name: String.t(), type: String.t() | nil}]) :: [map()]
  def readings(inputs, declared) when is_map(inputs) do
    types = Map.new(declared, &{&1.name, &1.type})

    typed =
      Map.new(inputs, fn {name, value} -> {name, revive(value, Map.get(types, name))} end)

    Enum.uniq([typed, inputs])
  end

  @doc """
  One stored value read as the FEEL type `type`. A value that does not read as that type is
  returned unchanged: it may have been handed to the engine as it is.
  """
  @spec revive(term(), String.t() | nil) :: term()
  def revive(value, type) when type in ["number", "integer", "long", "double"],
    do: number(value)

  def revive(value, "boolean") when value in ["true", "false"], do: value == "true"
  def revive(value, "date") when is_binary(value), do: parse(value, &Date.from_iso8601/1, "D")
  def revive(value, "time") when is_binary(value), do: parse(value, &Time.from_iso8601/1, "T")

  def revive(value, type) when type in ["dateTime", "date and time"] and is_binary(value),
    do: date_time(value)

  def revive(value, _type), do: value

  defp number(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = number, ""} -> number
      _ -> value
    end
  end

  defp number(value) when is_integer(value), do: Decimal.new(value)
  defp number(value) when is_float(value), do: Decimal.from_float(value)
  defp number(value), do: value

  # ISO 8601 text, or the `inspect/1` text (`~D[2026-01-15]`) rows carried before dates were
  # recorded as ISO 8601.
  defp parse(text, from_iso8601, sigil) do
    case from_iso8601.(unsigil(text, sigil)) do
      {:ok, value} -> value
      _ -> text
    end
  end

  defp date_time(text) do
    case DateTime.from_iso8601(unsigil(text, "U")) do
      {:ok, value, _offset} ->
        value

      _ ->
        case NaiveDateTime.from_iso8601(unsigil(text, "N")) do
          {:ok, value} -> value
          _ -> text
        end
    end
  end

  defp unsigil(text, sigil) do
    case Regex.run(~r/\A~#{sigil}\[(.+)\]\z/, text) do
      [_, inner] -> inner
      nil -> text
    end
  end
end

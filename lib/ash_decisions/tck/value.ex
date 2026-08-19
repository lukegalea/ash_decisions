defmodule AshDecisions.Tck.Value do
  @moduledoc """
  Reads the typed values in a TCK expectation file, and decides whether an engine result
  matches one.

  ## Why temporal values are built by evaluating FEEL

  A `<value xsi:type="xsd:date">2016-01-01</value>` has to be compared against whatever the
  engine returns for a FEEL date, and every engine represents those differently. Rather than
  guess at that representation — and quietly get the comparison wrong in a way that inflates
  or deflates a conformance score — this module constructs the expected value by asking the
  engine itself to evaluate `date("2016-01-01")`. The comparison is then between two values
  the engine produced, which is the only comparison that means anything.

  ## Why numbers are compared at the expectation's precision

  FEEL specifies decimal128 arithmetic — 34 significant digits. The corpus writes its
  expectations rounded, so `0008-LX-arithmetic` expects `2778.69354943277` where a conforming
  engine computes `2778.693549432766768088520383236288`. Comparing those with
  `Decimal.equal?/2` marks a *correct* engine wrong, and doing so across the arithmetic groups
  is enough to move the headline score by several points.

  So a number matches when it agrees with the expectation **to the precision the expectation
  states**. That is the convention the TCK's own runners use, and it is the only one under
  which a decimal128 engine can pass at all.
  """

  alias AshDecisions.Tck.Xml

  @doc """
  Reads a value-bearing node — `inputNode`, `expected`, `item` or `component` — into a plain
  Elixir term.

  The three shapes are mutually exclusive and recursive: a scalar `<value>`, a `<list>` of
  `<item>`s, or one or more `<component name=...>` children forming a context.
  """
  @spec read(Xml.element()) :: {:ok, term()} | {:error, String.t()}
  def read(node) do
    cond do
      (list = Xml.child(node, "list")) != nil -> read_list(list)
      (components = Xml.children(node, "component")) != [] -> read_components(components)
      (value = Xml.child(node, "value")) != nil -> read_scalar(value)
      true -> {:ok, nil}
    end
  end

  defp read_list(list) do
    list
    |> Xml.children("item")
    |> collect(&read/1)
  end

  defp read_components(components) do
    components
    |> collect(fn c ->
      with {:ok, v} <- read(c), do: {:ok, {Xml.attr(c, "name"), v}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Map.new(pairs)}
      error -> error
    end
  end

  defp read_scalar(value) do
    if Xml.attr(value, "nil") in ["true", "1"] do
      {:ok, nil}
    else
      cast(Xml.attr(value, "type"), Xml.raw_text(value))
    end
  end

  # `xsi:type` arrives prefixed (`xsd:decimal`); Xml.attr strips namespaces from the
  # attribute *name*, not its value, so strip the value's prefix here.
  defp cast(nil, text), do: {:ok, text}

  defp cast(type, text) do
    case type |> String.split(":") |> List.last() do
      # Only strings keep their surrounding whitespace; for every other type it is XML
      # indentation rather than data.
      "string" -> {:ok, text}
      "boolean" -> {:ok, String.trim(text) in ["true", "1"]}
      n when n in ["decimal", "double", "integer", "int", "long", "float"] -> number(String.trim(text))
      t when t in ["date", "time", "dateTime", "duration"] -> temporal(t, String.trim(text))
      other -> {:error, "unsupported xsi:type #{inspect(other)}"}
    end
  end

  defp number(text) do
    case Decimal.parse(text) do
      {decimal, ""} -> {:ok, decimal}
      _ -> {:error, "not a number: #{inspect(text)}"}
    end
  end

  # See the moduledoc: temporal expectations are constructed through the engine so that both
  # sides of the comparison share one representation.
  defp temporal(type, text) do
    constructor =
      case type do
        "date" -> "date"
        "time" -> "time"
        "dateTime" -> "date and time"
        "duration" -> "duration"
      end

    case Boxic.FEEL.evaluate(~s|#{constructor}("#{text}")|, %{}) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, "could not build #{type} #{inspect(text)}: #{inspect(reason)}"}
    end
  end

  @doc """
  Whether an engine result matches an expected value.

  Deliberately structural rather than `==`: maps compare key-by-key and lists
  element-by-element so that a nested difference is a mismatch at the leaf rather than an
  opaque whole-value inequality, and numbers compare numerically.
  """
  @spec matches?(term(), term()) :: boolean()
  def matches?(expected, actual)

  def matches?(%Decimal{} = expected, actual) when is_number(actual),
    do: matches?(expected, to_decimal(actual))

  def matches?(expected, %Decimal{} = actual) when is_number(expected),
    do: matches?(to_decimal(expected), actual)

  def matches?(%Decimal{} = expected, %Decimal{} = actual), do: numbers_agree?(expected, actual)

  def matches?(expected, actual) when is_number(expected) and is_number(actual),
    do: numbers_agree?(to_decimal(expected), to_decimal(actual))

  # Same-struct values (durations, dates, times) are compared field by field rather than with
  # `==`, because a numeric field can legitimately arrive as an integer from one code path and
  # a Decimal from another -- `duration("P1D")` and `date and time(...) - date and time(...)`
  # produce the same duration by different routes.
  def matches?(%mod{} = expected, %mod{} = actual) do
    expected
    |> Map.from_struct()
    |> Enum.all?(fn {k, v} -> matches?(v, Map.get(actual, k, :__absent__)) end)
  end

  def matches?(%_{}, _), do: false
  def matches?(_, %_{}), do: false

  def matches?(expected, actual) when is_map(expected) and is_map(actual) do
    map_size(expected) == map_size(actual) and
      Enum.all?(expected, fn {k, v} -> matches?(v, Map.get(actual, k, :__absent__)) end)
  end

  def matches?(expected, actual) when is_list(expected) and is_list(actual) do
    length(expected) == length(actual) and
      expected |> Enum.zip(actual) |> Enum.all?(fn {e, a} -> matches?(e, a) end)
  end

  def matches?(expected, actual), do: expected == actual

  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  # Agreement at the expectation's own precision. An expectation written to eleven decimal
  # places asserts nothing about the twelfth, so both sides are rounded to it before
  # comparing. An integral expectation is compared exactly.
  defp numbers_agree?(expected, actual) do
    places = -Decimal.scale(expected)

    if places >= 0 do
      Decimal.equal?(expected, actual)
    else
      Decimal.equal?(
        Decimal.round(expected, -places, :half_even),
        Decimal.round(actual, -places, :half_even)
      )
    end
  rescue
    # Rounding an infinity or NaN raises; fall back to exact comparison rather than
    # silently calling them equal.
    _ -> Decimal.equal?(expected, actual)
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end

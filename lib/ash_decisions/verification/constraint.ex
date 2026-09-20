defmodule AshDecisions.Verification.Constraint do
  @moduledoc """
  Lowers a decision table input entry into a constraint, or refuses to guess.

  Verification needs input entries as *terms*, not text. This module recognises
  the decidable subset of the unary-test grammar — the same grammar
  `AshDecisions.Feel.evaluate_unary_test/4` runs at evaluation time — and lowers
  one cell into a constraint:

      {:point, "gold"}          # "gold"
      {:range, :unbounded, {:incl, 1000}}
                                # <= 1000
      {:range, {:incl, 1}, {:excl, 5}}
                                # [1..5)
      {:not, [{:point, "gold"}]}
                                # not("gold")
      :any                      # "-" or an empty cell
      {:union, constraints}     # a top-level comma disjunction
      {:opaque, text}           # everything else

  It runs at publish only; evaluation continues to go through the seam,
  unchanged. Parsing goes through `AshDecisions.Feel.parse/1` — the module's
  bounds and cache included — so a cell cannot lower differently from the way it
  evaluates.

  ## The sink is load-bearing

  `{:opaque, text}` is what a cell lowers to when its meaning is not decidable
  here: a function call, a qualified name, a reference to the context,
  `date(...)` arithmetic, or anything else the recognizer has not been taught.

  > **Soundness rule, normative.** The recognizer must never narrow. If it
  > cannot prove the precise constraint it must emit `{:opaque, text}`, and
  > `:opaque` is always a legal answer. A false `{:point, "gold"}` turns a
  > correct table into a reported overlap, and a verifier that reports false
  > findings gets switched off.

  ## One dispatch, mirrored

  A unary test is not one grammar but a small dispatch, and the engine's own
  dispatch is textual. This module mirrors
  `Boxic.FEEL.Evaluator.evaluate_unary_test/3` clause for clause — `-`,
  `not(...)`, a leading comparator, a leading `[` or `(` read as a range,
  otherwise an endpoint expression — so a cell the recognizer calls malformed is
  precisely a cell the engine will fail on at runtime, and not one expression
  more. All leaf expressions are parsed by the engine's own parser.
  """

  alias AshDecisions.Feel

  @typedoc "One end of an interval: inclusive, exclusive, or open."
  @type bound :: {:incl, term()} | {:excl, term()} | :unbounded

  @type t ::
          {:point, term()}
          | {:range, bound(), bound()}
          | {:not, [t()]}
          | :any
          | {:union, [t()]}
          | {:opaque, String.t()}

  @typedoc """
  Why a cell could not be parsed at all.

  `offset` is the byte offset of `part` within the whole cell, as carried by
  `AshDecisions.Feel.split_unary_tests_with_offsets/1`. A parse failure is a
  publish-blocking `:malformed_entry` finding, not an obligation: the engine
  will fail on this cell every time the row is reached.
  """
  @type failure :: %{
          code: atom(),
          message: String.t(),
          offset: non_neg_integer(),
          part: String.t()
        }

  # The engine's own comparator test, verbatim in shape: a leading comparator
  # operator makes the rest of the cell an operand expression.
  @comparator ~r/^(?<op><=|>=|<|>|!=|=)\s*(?<rhs>.+)$/s

  @doc """
  Lowers one input entry into a constraint.

  `nil` (a cell the snapshot stores as empty) lowers to `:any`, the same answer
  evaluation gives an empty cell. Returns `{:error, failure}` when the cell does
  not parse — the engine would fail on it at runtime.
  """
  @spec lower(String.t() | nil) :: {:ok, t()} | {:error, failure()}
  def lower(nil), do: {:ok, :any}

  def lower(text) when is_binary(text) do
    with :ok <- Feel.check_size(text) do
      lower_parts(Feel.split_unary_tests_with_offsets(text), text)
    end
  end

  # -- the top-level disjunction ----------------------------------------------

  defp lower_parts(parts, cell) do
    lowered = Enum.map(parts, &lower_single/1)

    case Enum.find(lowered, &match?({:error, _}, &1)) do
      {:error, _} = failure ->
        failure

      nil ->
        {:ok, lowered |> Enum.map(fn {:ok, constraint} -> constraint end) |> combine(cell)}
    end
  end

  defp combine([single], _cell), do: single

  defp combine(lowered, cell) do
    cond do
      # A disjunction with a wildcard is the wildcard.
      :any in lowered ->
        :any

      # A disjunction with an unprovable part is unprovable as a whole. Keeping
      # the provable parts would be an over-claim: the cell as a whole matches
      # more than any of them says.
      Enum.any?(lowered, &match?({:opaque, _}, &1)) ->
        {:opaque, cell}

      true ->
        {:union, lowered}
    end
  end

  # -- one unary test, dispatched exactly like the engine ----------------------

  defp lower_single({offset, part}) do
    cond do
      part == "-" ->
        {:ok, :any}

      String.starts_with?(part, "not(") and String.ends_with?(part, ")") ->
        lower_not(part, offset)

      Regex.match?(@comparator, part) ->
        lower_comparator(part, offset)

      String.starts_with?(part, "[") or String.starts_with?(part, "(") ->
        lower_range(part, offset)

      true ->
        lower_endpoint(part, offset)
    end
  end

  # The text between the parentheses is one unary test, not a disjunction: the
  # splitter has already run at the top level and does not respect parentheses,
  # which is also exactly how `not("a", "b")` fails to parse in the engine. The
  # recursion mirrors that, quirks included — a quirk the engine has is a quirk
  # this recognizer must share, or stage one would pass cells the engine fails.
  defp lower_not(part, offset) do
    inner = String.slice(part, 4, String.length(part) - 5)

    case lower_single({offset + 4, inner}) do
      {:ok, :any} -> {:ok, {:not, [:any]}}
      {:ok, {:opaque, _}} -> {:ok, {:opaque, part}}
      {:ok, constraint} -> {:ok, {:not, [constraint]}}
      {:error, _} = failure -> failure
    end
  end

  defp lower_comparator(part, offset) do
    %{"op" => op, "rhs" => rhs} = Regex.named_captures(@comparator, part)

    case Feel.parse(rhs) do
      {:ok, {:literal, value}} ->
        {:ok, comparator_constraint(op, value)}

      # An operand that is not a literal is a perfectly good cell the verifier
      # does not decide — the engine evaluates it against the context.
      {:ok, _} ->
        {:ok, {:opaque, part}}

      {:error, %{code: code, message: message}} ->
        {:error,
         %{
           code: code,
           message: message,
           offset: offset + (byte_size(part) - byte_size(rhs)),
           part: rhs
         }}
    end
  end

  defp comparator_constraint("=", value), do: {:point, value}
  defp comparator_constraint("!=", value), do: {:not, [{:point, value}]}
  defp comparator_constraint("<", value), do: {:range, :unbounded, {:excl, value}}
  defp comparator_constraint("<=", value), do: {:range, :unbounded, {:incl, value}}
  defp comparator_constraint(">", value), do: {:range, {:excl, value}, :unbounded}
  defp comparator_constraint(">=", value), do: {:range, {:incl, value}, :unbounded}

  defp lower_range(part, offset) do
    case Feel.parse(part) do
      {:ok, {:range, start_incl?, end_incl?, start_ast, end_ast}} ->
        lower_range_bounds(part, start_incl?, end_incl?, start_ast, end_ast)

      # The engine reads a cell that starts with `[` or `(` as a range and
      # errors ("expected a range") when it evaluates to anything else — so a
      # cell like `(1)` is a publish-blocking parse failure, not a shrug.
      {:ok, _ast} ->
        {:error,
         %{
           code: :range_expected,
           message:
             "the engine reads a cell that starts with '[' or '(' as a range, " <>
               "and this is not one",
           offset: offset,
           part: part
         }}

      {:error, %{code: code, message: message}} ->
        {:error, %{code: code, message: message, offset: offset, part: part}}
    end
  end

  defp lower_range_bounds(part, start_incl?, end_incl?, start_ast, end_ast) do
    with {:ok, lo} <- literal_bound(start_incl?, start_ast),
         {:ok, hi} <- literal_bound(end_incl?, end_ast) do
      range_or_opaque(part, lo, hi)
    end
  end

  defp range_or_opaque(part, lo, hi) do
    if :opaque in [lo, hi] do
      {:ok, {:opaque, part}}
    else
      {:ok, {:range, lo, hi}}
    end
  end

  defp literal_bound(true, {:literal, value}), do: {:ok, {:incl, value}}
  defp literal_bound(false, {:literal, value}), do: {:ok, {:excl, value}}

  # A range endpoint that is not a literal (`[a..b]`, `[1..max(x, y)]`) is a
  # legal cell — the engine evaluates the endpoint against the context — and an
  # unprovable one. One unprovable end poisons the whole cell.
  defp literal_bound(_incl?, _ast), do: {:ok, :opaque}

  # A bare endpoint is an equality test. (A literal list is unreachable here:
  # any cell starting with `[` is dispatched as a range first, exactly as the
  # engine dispatches it — and `[1, 2]` fails there because the splitter has
  # already cut it at the comma, which is the engine's own behaviour too.)
  defp lower_endpoint(part, offset) do
    case Feel.parse(part) do
      {:ok, {:literal, value}} ->
        {:ok, {:point, value}}

      {:ok, _} ->
        {:ok, {:opaque, part}}

      {:error, %{code: code, message: message}} ->
        {:error, %{code: code, message: message, offset: offset, part: part}}
    end
  end
end

# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Verification.ConstraintTest do
  @moduledoc """
  What the recognizer lowers, and — the load-bearing half — what it refuses to
  guess at.

  Every "lowers" case below is a cell the engine will answer at runtime, and the
  constraint must say exactly what the engine would answer. Every "refuses"
  case is either `:opaque` (a cell the engine runs fine that the verifier does
  not decide) or a parse failure (a cell the engine itself will fail on, which
  is a publish-blocking problem, not a shrug).
  """

  use ExUnit.Case, async: true

  alias AshDecisions.Verification.Constraint

  describe "lowers the decidable subset" do
    test "a wildcard, in both spellings" do
      assert {:ok, :any} = Constraint.lower("-")
      assert {:ok, :any} = Constraint.lower("")
      # an empty cell is stored as nil by the snapshot
      assert {:ok, :any} = Constraint.lower(nil)
      assert {:ok, :any} = Constraint.lower("   ")
    end

    test "literal points: strings, numbers, booleans, null" do
      assert {:ok, {:point, "gold"}} = Constraint.lower(~s|"gold"|)
      assert {:ok, {:point, %Decimal{} = d}} = Constraint.lower("42")
      assert Decimal.equal?(d, Decimal.new(42))
      assert {:ok, {:point, true}} = Constraint.lower("true")
      assert {:ok, {:point, nil}} = Constraint.lower("null")
    end

    test "comparators become half-open ranges" do
      assert {:ok, {:range, :unbounded, {:excl, %Decimal{} = d}}} = Constraint.lower("< 10")
      assert Decimal.equal?(d, Decimal.new(10))
      assert {:ok, {:range, :unbounded, {:incl, _}}} = Constraint.lower("<= 10")
      assert {:ok, {:range, {:excl, _}, :unbounded}} = Constraint.lower("> 10")
      assert {:ok, {:range, {:incl, _}, :unbounded}} = Constraint.lower(">= 10")
    end

    test "equality and inequality comparators" do
      assert {:ok, {:point, "gold"}} = Constraint.lower(~s|= "gold"|)
      assert {:ok, {:not, [{:point, %Decimal{} = d}]}} = Constraint.lower("!= 5")
      assert Decimal.equal?(d, Decimal.new(5))
    end

    test "closed ranges, with their bracket inclusivity" do
      assert {:ok, {:range, {:incl, a}, {:incl, b}}} = Constraint.lower("[1..5]")
      assert Decimal.equal?(a, Decimal.new(1))
      assert Decimal.equal?(b, Decimal.new(5))

      assert {:ok, {:range, {:excl, _}, {:excl, _}}} = Constraint.lower("(1..5)")
      assert {:ok, {:range, {:incl, _}, {:excl, _}}} = Constraint.lower("[1..5)")
    end

    test "a comma disjunction becomes a union, split the way the engine splits" do
      assert {:ok, {:union, [{:point, "a"}, {:point, "b"}]}} = Constraint.lower(~s|"a", "b"|)

      # a comma inside a string literal is not a separator
      assert {:ok, {:point, "a, b"}} = Constraint.lower(~s|"a, b"|)

      assert {:ok, {:union, [p1, p2, p3]}} = Constraint.lower("1, 2, 3")
      assert Enum.all?([p1, p2, p3], &match?({:point, %Decimal{}}, &1))
    end

    test "a disjunction with a wildcard is the wildcard" do
      assert {:ok, :any} = Constraint.lower(~s|"a", -|)
    end

    test "a FEEL list literal is split at its comma and fails, exactly as in the engine" do
      # The splitter does not respect brackets, and neither does the engine's:
      # `[1, 2]` is cut into `[1` and `2]` before either is parsed.
      assert {:error, %{}} = Constraint.lower("[1, 2]")
    end

    test "negation of a point, a range, and the wildcard" do
      assert {:ok, {:not, [{:point, "gold"}]}} = Constraint.lower(~s|not("gold")|)
      assert {:ok, {:not, [{:range, {:incl, _}, {:excl, _}}]}} = Constraint.lower("not([1..5))")
      assert {:ok, {:not, [:any]}} = Constraint.lower("not(-)")
      assert {:ok, {:not, [{:range, _lo, :unbounded}]}} = Constraint.lower("not(>= 5)")
    end
  end

  describe "refuses to guess, as opaque" do
    test "function calls, qualified names and arithmetic endpoints" do
      assert {:ok, {:opaque, "date(\"2020-01-01\")"}} =
               Constraint.lower(~s|date("2020-01-01")|)

      # single-argument calls parse and evaluate fine — they are just not
      # decidable here
      assert {:ok, {:opaque, _}} = Constraint.lower("upper_case(tier)")
      assert {:ok, {:opaque, _}} = Constraint.lower("tier")
      assert {:ok, {:opaque, _}} = Constraint.lower("a + 1")
      assert {:ok, {:opaque, _}} = Constraint.lower("orderTotal > 5")
    end

    test "a range endpoint that is not a literal poisons the whole cell" do
      assert {:ok, {:opaque, "[a..5]"}} = Constraint.lower("[a..5]")
      assert {:ok, {:opaque, "[1..x]"}} = Constraint.lower("[1..x]")
    end

    test "a comparator operand that is not a literal poisons the whole cell" do
      assert {:ok, {:opaque, ">= tier"}} = Constraint.lower(">= tier")
    end

    test "a disjunction with an unprovable part is unprovable as a whole" do
      assert {:ok, {:opaque, _}} = Constraint.lower(~s|"gold", upper_case(tier) = "GOLD"|)
    end

    test "negation of the unprovable is unprovable" do
      assert {:ok, {:opaque, _}} = Constraint.lower("not(upper_case(tier) = \"GOLD\")")
    end
  end

  describe "refuses outright when the engine itself would fail" do
    test "an unterminated string is a parse failure, with the part and offset" do
      assert {:error, %{code: :invalid_syntax, message: message, offset: 0, part: "\"gold"}} =
               Constraint.lower("\"gold")

      assert is_binary(message)
    end

    test "the offset points at the part that failed, not at the whole cell" do
      # `"a", 1 +` splits into `"a"` and `1 +`; the second part fails, at byte 5.
      assert {:error, %{offset: 5, part: "1 +"}} = Constraint.lower("\"a\", 1 +")
    end

    test "a multi-argument call is cut at its comma, and fails, exactly as in the engine" do
      # The splitter is quote-aware, not parenthesis-aware — deliberately, so a
      # recognizer cannot answer a cell differently from the evaluator.
      assert {:error, %{}} = Constraint.lower(~s|matches(tier, "g")|)
    end

    test "a cell that starts with ( or [ must be a range, as the engine demands" do
      assert {:error, %{code: :range_expected}} = Constraint.lower("[1]")
      assert {:error, %{code: :range_expected}} = Constraint.lower("(1)")
    end

    test "not(...) with a comma inside is split first, and then fails, as in the engine" do
      assert {:error, %{}} = Constraint.lower(~s|not("a", "b")|)
    end

    test "an expression that is not a unary test at all" do
      assert {:error, %{code: :invalid_syntax}} = Constraint.lower(">= ")
    end

    test "the size bound applies before anything else" do
      assert {:error, %{code: :expression_too_large}} =
               Constraint.lower(String.duplicate("> 1 or ", 1000) <> "> 1")
    end
  end
end

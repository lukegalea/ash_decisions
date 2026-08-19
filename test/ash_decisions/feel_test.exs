defmodule AshDecisions.FeelTest do
  @moduledoc """
  The FEEL seam and the three bounds it enforces.

  Rules are authored by tenant administrators, so every expression that reaches
  this module is a string somebody else wrote that this application is about to
  run. The bounds are not tuning; they are the reason that is an acceptable thing
  to do.
  """

  use ExUnit.Case, async: false

  alias AshDecisions.Feel

  describe "parse and evaluate" do
    test "evaluates an expression against a context" do
      assert {:ok, result} =
               Feel.evaluate("price * quantity", %{
                 "price" => Decimal.new("12.50"),
                 "quantity" => Decimal.new("2")
               })

      assert Decimal.equal?(result, Decimal.new("25.00"))
    end

    test "reports a parse failure as a flat map rather than an engine struct" do
      assert {:error, %{code: code, message: message}} = Feel.parse("1 +")
      assert is_atom(code)
      assert is_binary(message)
    end

    test "evaluates a unary test, which is the grammar a decision table cell uses" do
      assert {:ok, true} = Feel.evaluate_unary_test(">= 18", Decimal.new("21"))
      assert {:ok, false} = Feel.evaluate_unary_test(">= 18", Decimal.new("17"))
      assert {:ok, true} = Feel.evaluate_unary_test(~s|"a", "b"|, "b")
    end
  end

  describe "the bounds" do
    test "an expression larger than the size bound is refused before it is parsed" do
      assert {:error, %{code: :expression_too_large}} =
               Feel.parse("1" <> String.duplicate(" + 1", 2000))
    end

    test "the size bound applies to unary tests too" do
      assert {:error, %{code: :expression_too_large}} =
               Feel.evaluate_unary_test(String.duplicate("> 1 or ", 1000) <> "> 1", 2)
    end

    test "an expression deeper than the depth bound is refused after it is parsed" do
      assert {:error, %{code: :expression_too_deep}} = Feel.parse("1 + 2 * 3", max_depth: 1)
      assert {:ok, _} = Feel.parse("1 + 2 * 3", max_depth: 32)
    end

    test "an evaluation that outruns the timeout is killed, and says so" do
      # `for` over a large range is the cheapest way to spend real time inside
      # the evaluator without depending on a particular pathological input.
      assert {:error, %{code: :timeout, message: message}} =
               Feel.evaluate("sum(for i in 1..2000000 return i * 2)", %{}, timeout: 20)

      assert message =~ "20ms"
    end

    test "the caller survives the kill" do
      # The point of `Task.shutdown(task, :brutal_kill)` over anything the
      # evaluator could be asked to check: the process running the expression is
      # linked, so getting this wrong takes the caller down with it.
      Feel.evaluate("sum(for i in 1..2000000 return i * 2)", %{}, timeout: 10)
      assert {:ok, _} = Feel.evaluate("1 + 1", %{})
    end
  end

  describe "external functions" do
    test "are not available, which is the same answer the TCK expects" do
      # No `:external_functions` registry is ever passed, so the name simply does
      # not resolve. `AshDecisions.Tck.ExpectedFailures` lists the corresponding
      # TCK group as a permanent expected failure for exactly this reason.
      assert {:error, _} =
               Feel.evaluate(
                 ~s|function(x) external { java: { class: "java.lang.Math", method signature: "abs(int)" } }|,
                 %{}
               )
    end
  end

  describe "the parse cache" do
    test "a cached expression gives the same result as an uncached one" do
      Feel.flush_cache()

      assert {:ok, first} = Feel.parse("1 + 2")
      assert {:ok, second} = Feel.parse("1 + 2")
      assert {:ok, uncached} = Feel.parse("1 + 2", cache: false)

      assert first == second
      assert first == uncached
    end

    test "flush_cache empties it without breaking anything" do
      assert {:ok, _} = Feel.parse("2 + 2")
      assert :ok = Feel.flush_cache()
      assert {:ok, _} = Feel.parse("2 + 2")
    end

    test "reaching the bound stops the cache growing rather than evicting" do
      Feel.flush_cache()

      # With a limit of one, the second distinct expression is parsed every time
      # and never stored -- slow, which is the correct failure when the input is
      # tenant-authored.
      Application.put_env(:ash_decisions, :feel_cache_limit, 1)

      on_exit(fn ->
        Application.delete_env(:ash_decisions, :feel_cache_limit)
        Feel.flush_cache()
      end)

      assert {:ok, _} = Feel.parse("1 + 1")
      assert {:ok, _} = Feel.parse("2 + 2")
      assert {:ok, _} = Feel.parse("2 + 2")
    end
  end

  describe "print/1" do
    test "renders engine values as the FEEL that would produce them" do
      assert Feel.print(nil) == "null"
      assert Feel.print(true) == "true"
      assert Feel.print(Decimal.new("0.15")) == "0.15"
      assert Feel.print("gold") == ~s|"gold"|
      assert Feel.print(~D[2026-08-19]) == ~s|date("2026-08-19")|
      assert Feel.print([Decimal.new(1), "a"]) == ~s|[1, "a"]|
      assert Feel.print(%{"b" => "x", "a" => Decimal.new(1)}) == ~s|{a: 1, b: "x"}|
    end

    test "round-trips a value through the evaluator" do
      assert {:ok, value} = Feel.evaluate(~s|{tier: "gold", rate: 0.15}|, %{})
      assert {:ok, again} = Feel.evaluate(Feel.print(value), %{})
      assert again == value
    end

    test "escapes what would otherwise change the meaning of the source" do
      assert Feel.print(~s|say "hi"|) == ~s|"say \\"hi\\""|
    end
  end
end

defmodule AshDecisions.CompilerTest do
  @moduledoc """
  What the compiler accepts, and — mostly — what it refuses.

  The refusals are the interesting half. A DMN document is drawn by one person
  and executed by a machine, and the whole arrangement rests on the two being
  about the same decision. Every test in the "refuses" block below is an element
  that a designer would happily draw and that this package will not silently
  pretend it did not see.
  """

  use ExUnit.Case, async: true

  alias AshDecisions.Compiler

  defp fixture(name), do: File.read!("test/fixtures/#{name}.dmn")

  defp errors(name) do
    assert {:error, errors} = Compiler.compile(fixture(name))
    errors
  end

  defp messages(name), do: errors(name) |> Enum.map(& &1.message) |> Enum.join("\n")

  describe "a document it accepts" do
    test "snapshots the decision, its clauses, its hit policy and its rules" do
      assert {:ok, graph} = Compiler.compile(fixture("discount"))

      decision = graph["decisions"]["decision_discount"]

      assert decision["name"] == "Discount"
      assert decision["logic"] == "decisionTable"
      assert decision["hit_policy"] == "UNIQUE"
      assert Enum.map(decision["inputs"], & &1["label"]) == ["Order total", "Customer tier"]
      assert Enum.map(decision["outputs"], & &1["name"]) == ["discount"]

      assert Enum.map(decision["rules"], & &1["id"]) ==
               ~w(rule_gold_large rule_gold_small rule_standard)
    end

    test "stores FEEL source text, not a parsed tree" do
      assert {:ok, graph} = Compiler.compile(fixture("discount"))
      rule = hd(graph["decisions"]["decision_discount"]["rules"])

      assert rule["input_entries"] == [">= 1000", "\"gold\""]
      assert rule["output_entries"] == ["0.15"]
    end

    test "the snapshot is JSON, because it has to survive a round trip through a column" do
      assert {:ok, graph} = Compiler.compile(fixture("discount"))
      assert {:ok, encoded} = Jason.encode(graph)
      assert Jason.decode!(encoded) == graph
    end

    test "it records the engine version that validated the expressions" do
      assert {:ok, graph} = Compiler.compile(fixture("discount"))

      assert graph["feel_engine"]["name"] == "boxic_feel"
      assert graph["feel_engine"]["version"] =~ ~r/^\d+\.\d+/
    end

    test "a multi-decision DRD joined by informationRequirement is supported" do
      assert {:ok, graph} = Compiler.compile(fixture("drd"))

      assert graph["decision_order"] == ["decision_eligible", "decision_offer"]

      assert graph["decisions"]["decision_offer"]["requires"] == %{
               "decisions" => ["decision_eligible"],
               "input_data" => []
             }

      assert graph["decisions"]["decision_offer"]["logic"] == "literalExpression"

      assert graph["decisions"]["decision_offer"]["expression"] ==
               ~s|if Eligible then "standard" else "none"|
    end

    test "input data is snapshotted alongside the decisions that require it" do
      assert {:ok, graph} = Compiler.compile(fixture("discount"))

      assert graph["input_data"]["input_order_total"]["name"] == "orderTotal"

      assert graph["decisions"]["decision_discount"]["requires"]["input_data"] ==
               ["input_order_total", "input_customer_tier"]
    end
  end

  describe "what it refuses" do
    test "a boxed expression outside decisionTable and literalExpression, naming the element" do
      [error] = errors("boxed_context")

      assert error.path == "ctx_totals"
      assert error.message =~ "boxed expression 'context'"
      assert error.message =~ "decisionTable and literalExpression"
    end

    test "business knowledge models, and the knowledgeRequirement that points at one" do
      messages = messages("bkm")

      assert messages =~ "business knowledge models are not supported"
      assert messages =~ "knowledgeRequirement"
      assert Enum.map(errors("bkm"), & &1.path) == ["bkm_double", "decision_doubled"]
    end

    test "RULE ORDER, and says why rather than only that" do
      [error] = errors("rule_order")

      assert error.path == "table_discount"
      assert error.message =~ "RULE ORDER"
      assert error.message =~ "order of the result list"
      assert error.message =~ "UNIQUE, ANY, FIRST, PRIORITY and COLLECT"
    end

    test "OUTPUT ORDER, for the same reason" do
      assert messages("output_order") =~ "OUTPUT ORDER"
      assert messages("output_order") =~ "order of the result list"
    end

    test "an aggregation on a table that is not COLLECT, which the engine would ignore" do
      [error] = errors("stray_aggregation")

      assert error.message =~ "aggregation 'SUM' is set on a UNIQUE table"
      assert error.message =~ "only under COLLECT"
    end

    test "a requirement that does not resolve" do
      [error] = errors("dangling")

      assert error.path == "decision_orphan"
      assert error.message =~ "decision_that_is_not_here"
      assert error.message =~ "does not resolve"
    end

    test "a requirement cycle, naming every decision caught in it" do
      assert Enum.map(errors("cycle"), & &1.path) == ["decision_a", "decision_b"]
      assert messages("cycle") =~ "requirement cycle"
    end

    test "an expression that does not parse, against the rule that contains it" do
      [error] = errors("bad_feel")

      assert error.path == "rule_gold_large"
      assert error.message =~ "output entry 1 does not compile"
    end

    test "XML that is not XML" do
      assert {:error, [error]} = Compiler.compile("this is not a document")
      assert error.path == "document"
    end
  end

  describe "compile!/1" do
    test "raises with every error formatted, so one run tells an author everything" do
      exception = assert_raise RuntimeError, fn -> Compiler.compile!(fixture("bkm")) end

      assert Exception.message(exception) =~ "DMN compilation failed"
      assert Exception.message(exception) =~ "[bkm_double]"
      assert Exception.message(exception) =~ "[decision_doubled]"
    end

    test "returns the graph when there is nothing to say" do
      assert %{"decisions" => _} = Compiler.compile!(fixture("discount"))
    end
  end
end

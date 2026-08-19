defmodule AshDecisions.EvaluatorTest do
  @moduledoc """
  Evaluating a published decision, and the specification-revision gap that had to be closed
  before a decision drawn in a designer could be run at all.
  """

  use ExUnit.Case, async: false

  alias AshDecisions.Dmn.Profile
  alias AshDecisions.Evaluator

  @discount File.read!("test/fixtures/discount.dmn")

  # Not a fixture on disk: derived from the real one, so it cannot drift away from it.
  defp as_dmn_13(xml) do
    xml
    |> String.replace(
      "https://www.omg.org/spec/DMN/20230324/MODEL/",
      "https://www.omg.org/spec/DMN/20191111/MODEL/"
    )
    |> String.replace(
      "https://www.omg.org/spec/DMN/20230324/FEEL/",
      "https://www.omg.org/spec/DMN/20191111/FEEL/"
    )
  end

  defp definition(xml, key \\ "discount") do
    %{
      id: nil,
      key: key,
      version: 1,
      xml: xml,
      content_hash: :sha256 |> :crypto.hash(xml) |> Base.encode16(case: :lower),
      graph: AshDecisions.Compiler.compile!(xml)
    }
  end

  setup do
    Evaluator.flush_cache(:all)
    :ok
  end

  describe "the DMN revision gap" do
    # The finding that made `AshDecisions.Dmn.Profile` necessary. Worth an explicit test
    # rather than a comment, because if the engine ever accepts 1.3 directly this test is how
    # anyone finds out that the normalization has become unnecessary.
    test "the engine refuses a DMN 1.3 document outright" do
      assert {:error, diagnostics} = Boxic.DMN.load_xml(as_dmn_13(@discount))
      assert Enum.any?(List.wrap(diagnostics), &(&1.code == :dmn_version_mismatch))
    end

    test "dmn-js's revision evaluates once normalized, and to the same answer" do
      inputs = %{"orderTotal" => 500, "customerTier" => "gold"}

      assert {:ok, from_15} =
               Evaluator.evaluate(definition(@discount, "d15"), inputs, record: false)

      assert {:ok, from_13} =
               Evaluator.evaluate(definition(as_dmn_13(@discount), "d13"), inputs, record: false)

      assert Decimal.equal?(from_15.outputs, from_13.outputs)
    end

    test "normalize/1 leaves a document that is already executable untouched" do
      assert Profile.normalize(@discount) == @discount
      assert Profile.executable?(@discount)
      refute Profile.executable?(as_dmn_13(@discount))
    end

    test "normalize/1 changes namespaces and nothing else" do
      normalized = Profile.normalize(as_dmn_13(@discount))

      # Same document, same length, same everything but the namespace URIs.
      assert normalized == @discount
    end
  end

  describe "evaluate/3" do
    # The trap `to_feel_value/2` exists for: an Elixir integer against a FEEL decimal literal
    # is a type error, which is null, which a decision table reads as "no rule matched". The
    # table then returns null and nothing reports a problem.
    test "a plain Elixir integer input still matches a numeric rule" do
      assert {:ok, %{outputs: outputs}} =
               Evaluator.evaluate(
                 definition(@discount),
                 %{"orderTotal" => 500, "customerTier" => "gold"},
                 record: false
               )

      refute is_nil(outputs)
    end

    test "reports the definition it used" do
      assert {:ok, result} =
               Evaluator.evaluate(
                 definition(@discount),
                 %{"orderTotal" => 500, "customerTier" => "gold"},
                 record: false
               )

      assert result.definition_key == "discount"
      assert result.definition_version == 1
      assert result.decision == "Discount"
      assert is_integer(result.duration_us)
    end

    test "a decision name that is not in the document is an error, not a nil answer" do
      assert {:error, {:evaluation_failed, _}} =
               Evaluator.evaluate(definition(@discount), %{"orderTotal" => 500},
                 decision: "NoSuchDecision",
                 record: false
               )
    end

    test "the model is cached by content hash, so a second evaluation does not reload it" do
      defn = definition(@discount)
      inputs = %{"orderTotal" => 500, "customerTier" => "gold"}

      assert {:ok, _} = Evaluator.evaluate(defn, inputs, record: false)
      assert {:ok, _} = Evaluator.evaluate(defn, inputs, record: false)

      # Loading shells out to xmllint, so the cache is not a micro-optimisation -- it is the
      # difference between one process spawn per deployment and one per decision.
      assert :persistent_term.get({{AshDecisions.Evaluator, :model}, defn.content_hash}, :miss) !=
               :miss
    end

    test "flush_cache/1 drops just that definition" do
      defn = definition(@discount)

      assert {:ok, _} =
               Evaluator.evaluate(defn, %{"orderTotal" => 500, "customerTier" => "gold"},
                 record: false
               )

      Evaluator.flush_cache(defn)

      assert :persistent_term.get({{AshDecisions.Evaluator, :model}, defn.content_hash}, :miss) ==
               :miss
    end
  end
end

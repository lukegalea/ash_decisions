# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.ReplayTest do
  @moduledoc """
  `AshDecisions.Replay`: recorded evaluations re-run against a candidate version. Who may
  replay what comes first, then the baseline control (a case counts only when its recorded
  answer reproduces), then each outcome, then input sets a host builds for a decision that
  records nothing.
  """

  use AshDecisions.DataCase, async: false

  alias AshDecisions.Evaluator
  alias AshDecisions.Replay
  alias AshDecisions.Scope
  alias AshDecisions.TrialHost.{Definition, Evaluation}

  setup do
    %{tenant: Ecto.UUID.generate(), key: "k#{System.unique_integer([:positive])}"}
  end

  # One decision, `Tier`, over a number. `opts` vary what a candidate changes.
  defp tier_xml(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 100)
    high_id = Keyword.get(opts, :high_id, "rule_high")
    name = Keyword.get(opts, :name, "Tier")
    hit_policy = Keyword.get(opts, :hit_policy, "FIRST")
    low_test = Keyword.get(opts, :low_test, "&lt;= #{threshold}")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 id="tier" name="tier" namespace="urn:test">
      <inputData id="input_amount" name="amount">
        <variable id="var_amount" name="amount" typeRef="number"/>
      </inputData>
      <decision id="decision_tier" name="#{name}">
        <informationRequirement id="req_amount">
          <requiredInput href="#input_amount"/>
        </informationRequirement>
        <decisionTable id="table_tier" hitPolicy="#{hit_policy}">
          <input id="clause_amount" label="Amount">
            <inputExpression id="expr_amount" typeRef="number"><text>amount</text></inputExpression>
          </input>
          <output id="clause_tier" name="tier" typeRef="string"/>
          <rule id="#{high_id}">
            <inputEntry id="rule_high_0"><text>&gt; #{threshold}</text></inputEntry>
            <outputEntry id="rule_high_1"><text>"high"</text></outputEntry>
          </rule>
          <rule id="rule_low">
            <inputEntry id="rule_low_0"><text>#{low_test}</text></inputEntry>
            <outputEntry id="rule_low_1"><text>"low"</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
    </definitions>
    """
  end

  defp engine(tenant), do: Scope.engine(%Scope{tenant: tenant})

  defp version!(tenant, key, xml),
    do: Definition.create!(%{key: key, name: key, xml: xml}, engine(tenant))

  defp published!(tenant, key, xml),
    do: tenant |> version!(key, xml) |> Definition.publish!(engine(tenant))

  # A real evaluation, recorded the way a host's governed path records it.
  defp decide!(tenant, definition, inputs) do
    _ =
      Evaluator.evaluate(definition, inputs,
        evaluation_resource: Evaluation,
        scope: %Scope{tenant: tenant},
        record: :required
      )

    :ok
  end

  defp reader, do: %{id: Ecto.UUID.generate(), decisions?: true}

  defp cases(tenant, key, opts \\ []),
    do: Replay.recorded(Definition, Evaluation, key, [actor: reader(), tenant: tenant] ++ opts)

  defp outcome_of(%{cases: cases}, amount) do
    Enum.find_value(cases, fn c -> c.inputs["amount"] == amount && c.outcome end)
  end

  describe "who may replay what" do
    test "a reader in the tenant gets the recorded cases, newest first", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => 50})
      decide!(t, v1, %{"amount" => 150})

      assert [%{inputs: %{"amount" => "150"}}, %{inputs: %{"amount" => "50"}}] = cases(t, key)
    end

    test "the engine bypass does not apply: no read, nothing to replay", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => 50})
      nobody = %{id: Ecto.UUID.generate(), decisions?: false}

      assert Replay.recorded(Definition, Evaluation, key, actor: nobody, tenant: t) == []
    end

    test "another tenant replays nothing", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => 50})

      assert cases(Ecto.UUID.generate(), key) == []
    end

    test "the newest :limit cases, and only this key's", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      other = published!(t, key <> "x", tier_xml())
      for amount <- [10, 20, 30], do: decide!(t, v1, %{"amount" => amount})
      decide!(t, other, %{"amount" => 40})

      assert [%{inputs: %{"amount" => "30"}}, %{inputs: %{"amount" => "20"}}] =
               cases(t, key, limit: 2)
    end

    test "a replay records nothing", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => 50})
      candidate = version!(t, key, tier_xml(threshold: 10))

      before = Ash.count!(Evaluation, authorize?: false, tenant: t)
      Replay.run(candidate, cases(t, key))
      assert Ash.count!(Evaluation, authorize?: false, tenant: t) == before
    end
  end

  describe "outcomes" do
    test "a moved threshold changes the cases it crosses, and only those", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml(threshold: 100))
      decide!(t, v1, %{"amount" => 50})
      decide!(t, v1, %{"amount" => 150})
      decide!(t, v1, %{"amount" => 250})

      candidate = version!(t, key, tier_xml(threshold: 200))
      result = Replay.run(candidate, cases(t, key))

      assert outcome_of(result, "150") == :changed
      assert outcome_of(result, "50") == :unchanged
      assert outcome_of(result, "250") == :unchanged
      assert %{changed: 1, unchanged: 2, unreproducible: 0} = result.counts

      changed = Enum.find(result.cases, &(&1.outcome == :changed))
      assert changed.before == %{answer: %{"value" => "high"}, rules: ["rule_high"], error: nil}
      assert changed.after == %{answer: %{"value" => "low"}, rules: ["rule_low"], error: nil}
      assert changed.version == v1.version
      assert changed.decision == "Tier"
    end

    test "the same answer from a renamed rule is :rules_changed", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => 150})

      result = Replay.run(version!(t, key, tier_xml(high_id: "rule_big")), cases(t, key))

      assert outcome_of(result, "150") == :rules_changed
    end

    test "a recorded failure the candidate answers is :now_answers", %{tenant: t, key: key} do
      # UNIQUE with two matching rules is a failure the engine reports, and it is recorded.
      v1 = version!(t, key, tier_xml(hit_policy: "UNIQUE", low_test: "&gt; 0"))
      decide!(t, v1, %{"amount" => 150})
      assert [%{recorded: %{error: error}}] = cases(t, key)
      assert is_binary(error)

      result = Replay.run(version!(t, key, tier_xml(hit_policy: "UNIQUE")), cases(t, key))

      assert outcome_of(result, "150") == :now_answers
    end

    test "an answer the candidate fails on is :now_fails", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml(hit_policy: "UNIQUE"))
      decide!(t, v1, %{"amount" => 150})

      candidate = version!(t, key, tier_xml(hit_policy: "UNIQUE", low_test: "&gt; 0"))
      assert outcome_of(Replay.run(candidate, cases(t, key)), "150") == :now_fails
    end

    test "a case whose decision the candidate dropped is :skipped", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => 150})

      result = Replay.run(version!(t, key, tier_xml(name: "Band")), cases(t, key))

      assert %{outcome: :skipped, after: nil} = hd(result.cases)
    end

    test "every outcome is counted, zero or not", %{tenant: t, key: key} do
      published!(t, key, tier_xml())
      result = Replay.run(version!(t, key, tier_xml()), cases(t, key))

      assert result.cases == []
      assert Map.keys(result.counts) |> Enum.sort() == Replay.outcomes() |> Keyword.keys() |> Enum.sort()
      assert Enum.all?(result.counts, fn {_outcome, n} -> n == 0 end)
    end
  end

  describe "the baseline control" do
    test "decimals recorded as strings reproduce through the declared type", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => Decimal.new("150.5")})

      assert [%{inputs: %{"amount" => "150.5"}}] = cases(t, key)
      assert outcome_of(Replay.run(v1, cases(t, key)), "150.5") == :unchanged
    end

    test "a row whose answer does not reproduce is never compared", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())

      # A record the version cannot have produced from these inputs: what a row looks like
      # when its inputs did not survive, or the decision read something besides them.
      Evaluation.create!(
        %{
          definition_id: v1.id,
          definition_key: key,
          definition_version: v1.version,
          decision_id: "Tier",
          inputs: %{"amount" => "150"},
          outputs: %{"value" => "low"},
          matched_rule_ids: ["rule_low"]
        },
        engine(t)
      )

      result = Replay.run(version!(t, key, tier_xml(threshold: 200)), cases(t, key))

      assert [%{outcome: :unreproducible, after: %{answer: %{"value" => "high"}}}] = result.cases
      assert result.counts.unreproducible == 1
      assert result.counts.changed == 0
    end

    test "inputs handed to the engine as strings replay as strings", %{tenant: t, key: key} do
      # A host that passes decimal strings on purpose (the judgments bridge does), and a table
      # that reads them with number().
      xml = tier_xml() |> String.replace("<text>amount</text>", "<text>number(amount)</text>")
      xml = String.replace(xml, ~s(name="amount" typeRef="number"), ~s(name="amount" typeRef="string"))
      v1 = published!(t, key, xml)
      decide!(t, v1, %{"amount" => "150"})

      assert outcome_of(Replay.run(v1, cases(t, key)), "150") == :unchanged
    end

    test "a candidate input the case never had is listed", %{tenant: t, key: key} do
      v1 = published!(t, key, tier_xml())
      decide!(t, v1, %{"amount" => 150})

      extra =
        String.replace(
          tier_xml(),
          ~s(<decision id="decision_tier"),
          ~s(<inputData id="input_region" name="region"><variable id="var_region" name="region" typeRef="string"/></inputData>\n  <decision id="decision_tier")
        )

      assert [%{missing_inputs: ["region"]}] = Replay.run(version!(t, key, extra), cases(t, key)).cases
    end
  end

  describe "compare/4, for a decision that records nothing" do
    test "compares a baseline with a candidate over input sets the host builds", %{tenant: t, key: key} do
      baseline = published!(t, key, tier_xml(threshold: 100))
      candidate = version!(t, key, tier_xml(threshold: 200))

      result =
        Replay.compare(baseline, candidate, [
          %{"amount" => Decimal.new(50)},
          %{"amount" => Decimal.new(150)}
        ])

      assert [%{id: 0, outcome: :unchanged}, %{id: 1, outcome: :changed, inputs: %{"amount" => "150"}}] =
               result.cases

      assert %{changed: 1, unchanged: 1} = result.counts
    end
  end
end

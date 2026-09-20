# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.VerifierTest do
  @moduledoc """
  What publish-time verification proves, and what it refuses to claim.

  The findings are the interesting half — but the tests that matter most are the
  ones asserting a finding is **absent**: an analysis that reports false
  overlaps gets switched off, so every clean table here is as deliberate as
  every dirty one. The obligations are the third answer, neither clean nor
  dirty: what the verifier could not decide, said out loud.
  """

  use ExUnit.Case, async: true

  alias AshDecisions.Compiler
  alias AshDecisions.Verifier

  defp fixture(name), do: File.read!("test/fixtures/#{name}.dmn")

  defp verify_xml(name) do
    {:ok, graph} = Compiler.compile(fixture(name))
    Verifier.verify(graph)
  end

  defp verify_table(table, decision_id \\ "d") do
    Verifier.verify(%{"decisions" => %{decision_id => table}, "decision_order" => [decision_id]})
  end

  defp reasons(result), do: Enum.map(result.obligations, & &1.reason)

  defp number_table(entries, policy, outputs \\ covering_output()) do
    %{
      "id" => "d",
      "logic" => "decisionTable",
      "hit_policy" => policy,
      "inputs" => [
        %{"id" => "c1", "label" => "amount", "type_ref" => "number", "input_values" => []}
      ],
      "outputs" => outputs,
      "rules" =>
        entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, i} ->
          %{"id" => "r#{i + 1}", "input_entries" => [entry], "output_entries" => ["1"]}
        end)
    }
  end

  # A default output entry, so completeness tests can ask for tables with gaps
  # explicitly and the overlap tests stay about overlap.
  defp covering_output,
    do: [%{"id" => "o1", "label" => "out", "default_output_entry" => "0"}]

  defp uncovered_output,
    do: [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}]

  describe "overlap" do
    test "a UNIQUE table whose rules can both match is an error, with a witness region" do
      result = verify_table(number_table([">= 1000", "> 500"], "UNIQUE"))

      finding = Enum.find(result.findings, &(&1.kind == :overlap))

      assert %{severity: :error, path: "r1", detail: detail} = finding
      assert detail["rules"] == ["r1", "r2"]
      assert detail["region"] != ""
      assert finding.message =~ "UNIQUE refuses"
    end

    test "half-open ranges that meet exactly do not overlap" do
      result = verify_table(number_table(["[100..200)", "[200..300]"], "UNIQUE"))

      refute Enum.any?(result.findings, &(&1.kind == :overlap))
    end

    test "ranges that share only a closed boundary do" do
      assert [%{kind: :overlap}] =
               verify_table(number_table(["[100..200]", "[200..300]"], "UNIQUE")).findings
    end

    test "a gap at the extremes is not an overlap" do
      result = verify_table(number_table([">= 1000", "< 1000"], "UNIQUE"))

      assert result.findings == []
    end

    test ~s<negation is decided: not("gold") overlaps a "silver" rule> do
      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [
          %{
            "id" => "tier",
            "label" => "Tier",
            "type_ref" => "string",
            "input_values" => ["gold", "silver"]
          }
        ],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => [
          %{"id" => "r1", "input_entries" => [~s|not("gold")|], "output_entries" => ["1"]},
          %{"id" => "r2", "input_entries" => [~s|"silver"|], "output_entries" => ["2"]}
        ]
      }

      finding = hd(verify_table(table).findings)
      assert finding.kind == :overlap
      assert finding.detail["region"] =~ "silver"
    end

    test ~s<negation is decided: not("gold") does not overlap a "gold" rule> do
      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [
          %{
            "id" => "tier",
            "label" => "Tier",
            "type_ref" => "string",
            "input_values" => ["gold", "silver"]
          }
        ],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => [
          %{"id" => "r1", "input_entries" => [~s|not("gold")|], "output_entries" => ["1"]},
          %{"id" => "r2", "input_entries" => [~s|"gold"|], "output_entries" => ["2"]}
        ]
      }

      assert verify_table(table).findings == []
    end

    test "ANY escalates only when the overlapping outputs differ" do
      same = verify_table(number_table([">= 100", "<= 500"], "ANY"))
      assert [%{kind: :overlap, severity: :info}] = same.findings

      differing = %{
        number_table([">= 100", "<= 500"], "ANY")
        | "rules" => [
            %{"id" => "r1", "input_entries" => [">= 100"], "output_entries" => ["1"]},
            %{"id" => "r2", "input_entries" => ["<= 500"], "output_entries" => ["2"]}
          ]
      }

      assert [%{kind: :overlap, severity: :error, message: message}] =
               verify_table(differing).findings

      assert message =~ "output entries differ"
    end

    test "FIRST and PRIORITY report overlaps as info" do
      assert [%{kind: :overlap, severity: :info}] =
               verify_table(number_table([">= 100", "<= 500"], "FIRST")).findings

      assert [%{kind: :overlap, severity: :info}] =
               verify_table(number_table([">= 100", "<= 500"], "PRIORITY")).findings
    end

    test "COLLECT declines to analyse overlap, and says so" do
      result = verify_table(number_table([">= 100", "<= 500"], "COLLECT"))

      assert result.findings == []
      assert reasons(result) == [:hit_policy]
    end

    test "the fixture overlap is found end to end, through the compiler" do
      result = verify_xml("verification_overlap")

      finding =
        Enum.find(result.findings, &(&1.kind == :overlap))

      assert %{severity: :error, path: "rule_gold_large", detail: detail} = finding
      assert detail["rules"] == ["rule_gold_large", "rule_gold_medium"]
      refute Enum.any?(result.obligations, &(&1.reason == :opaque_entry))
    end
  end

  describe "shadowed rules" do
    test "a FIRST rule fully covered by an earlier one is unreachable" do
      result = verify_table(number_table(["-", ">= 100"], "FIRST"))

      finding = Enum.find(result.findings, &(&1.kind == :shadowed))

      assert %{severity: :warning, detail: detail} = finding
      assert detail == %{"rule" => "r2", "subsumed_by" => "r1"}
      # and the overlap is still info, as FIRST allows
      assert Enum.any?(result.findings, &(&1.kind == :overlap and &1.severity == :info))
    end

    test "a later rule that extends an earlier one is not shadowed" do
      # r1 covers [500, ∞); r2 covers [100, ∞) and fires on [100, 500), where
      # nothing earlier has spoken.
      result = verify_table(number_table([">= 500", ">= 100"], "FIRST"))

      refute Enum.any?(result.findings, &(&1.kind == :shadowed))
    end

    test "shadowing is not claimed under other policies" do
      for policy <- ["UNIQUE", "ANY", "PRIORITY"] do
        refute Enum.any?(verify_table(number_table(["-", ">= 100"], policy)).findings, fn f ->
                 f.kind == :shadowed
               end)
      end
    end
  end

  describe "completeness" do
    test "a gap is a warning with a witness input" do
      result = verify_table(number_table([">= 1000", "< 500"], "UNIQUE", uncovered_output()))

      finding = hd(result.findings)
      assert finding.kind == :incomplete
      assert finding.severity == :warning
      assert finding.path == "d"
      assert finding.detail["gap_count"] == 2
      assert [%{"region" => region, "witness" => witness} | _] = finding.detail["gaps"]
      assert region =~ "amount"
      assert Map.has_key?(witness, "c1")
    end

    test "a table with a default output entry on every output clause is total" do
      outputs = [%{"id" => "o1", "label" => "out", "default_output_entry" => "0"}]
      result = verify_table(number_table([">= 1000", "< 500"], "UNIQUE", outputs))

      assert result.findings == []
    end

    test "an enumerated column is complete when every value is covered" do
      result = verify_xml("verification_enum")

      assert result.findings == []
      assert result.obligations == []
    end

    test "an enumerated column with a missing value has a gap naming the missing value" do
      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [
          %{
            "id" => "tier",
            "label" => "Tier",
            "type_ref" => "string",
            "input_values" => ["gold", "silver", "bronze"]
          }
        ],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => [
          %{"id" => "r1", "input_entries" => [~s|"gold"|], "output_entries" => ["1"]},
          %{"id" => "r2", "input_entries" => [~s|"silver"|], "output_entries" => ["2"]}
        ]
      }

      finding = hd(verify_table(table).findings)
      assert finding.kind == :incomplete
      assert finding.detail["gaps"] |> Enum.any?(&(&1["region"] =~ "bronze"))
    end

    test "a boolean column is a two-value domain" do
      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [
          %{"id" => "vip", "label" => "VIP", "type_ref" => "boolean", "input_values" => []}
        ],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => [
          %{"id" => "r1", "input_entries" => ["true"], "output_entries" => ["1"]}
        ]
      }

      finding = hd(verify_table(table).findings)
      assert finding.kind == :incomplete
      assert finding.detail["gaps"] |> Enum.any?(&(&1["region"] =~ "false"))
    end

    test "a lone wildcard makes a column total" do
      result = verify_table(number_table(["-"], "UNIQUE"))

      assert result.findings == []
    end

    test "COLLECT reports incompleteness as info" do
      result = verify_table(number_table([">= 1000", "< 500"], "COLLECT", uncovered_output()))

      assert [%{kind: :incomplete, severity: :info}] = result.findings
    end

    test "the incomplete fixture is a warning and still compiles clean" do
      result = verify_xml("verification_incomplete")

      assert [%{kind: :incomplete, severity: :warning}] = result.findings
      assert finding = hd(result.findings)
      assert finding.message =~ "null"
    end

    test "a default output entry covers the gap, in the fixture too" do
      result = verify_xml("verification_default")

      assert result.findings == []
    end
  end

  describe "unsatisfiable rules" do
    test "a rule that matches no region of the declared domain is an error" do
      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [
          %{
            "id" => "tier",
            "label" => "Tier",
            "type_ref" => "string",
            "input_values" => ["gold", "silver"]
          }
        ],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => [
          %{"id" => "r1", "input_entries" => [~s|"gold"|], "output_entries" => ["1"]},
          %{"id" => "r2", "input_entries" => [~s|"platinum"|], "output_entries" => ["2"]}
        ]
      }

      finding =
        verify_table(table).findings
        |> Enum.find(&(&1.kind == :unsatisfiable))

      assert finding.severity == :error
      assert finding.path == "r2"
      assert finding.message =~ "never fire"
    end

    test "not(-) can never fire" do
      result = verify_table(number_table([">= 100", "not(-)"], "UNIQUE"))

      assert Enum.any?(result.findings, &(&1.kind == :unsatisfiable and &1.path == "r2"))
    end

    test "a rule the analysis cannot decide is not called unsatisfiable" do
      result = verify_table(number_table([">= 100", "abs(c1) > 5"], "UNIQUE"))

      refute Enum.any?(result.findings, &(&1.kind == :unsatisfiable))
    end
  end

  describe "malformed entries" do
    test "a cell the engine cannot parse is a parse-stage error finding" do
      result = verify_xml("verification_malformed")

      finding = hd(result.findings)
      assert finding.kind == :malformed_entry
      assert finding.severity == :error
      assert finding.stage == :parse
      assert finding.path == "rule_typo"
      assert finding.message =~ "input entry 1 (Customer tier)"
      assert finding.message =~ "unterminated string"
      assert finding.detail["entry"] == "\"silver"
      assert is_integer(finding.detail["offset"])
    end

    test "a parse failure is the whole answer: no algebra runs on broken cells" do
      result = verify_xml("verification_malformed")

      assert Enum.count(result.findings, &(&1.stage == :parse)) == length(result.findings)
      assert result.obligations == []
    end
  end

  describe "obligations" do
    test "an opaque cell is recorded, and the analysis stays sound around it" do
      result = verify_xml("verification_opaque")

      assert result.findings == []

      assert [%{reason: :opaque_entry, path: "rule_g_tier", detail: detail}] = result.obligations
      assert detail["entry"] == ~s|upper_case(customerTier) = "GOLD"|
      assert detail["column"] == "clause_tier"
    end

    test "an untyped column is an obligation, and the points analysis still runs" do
      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [%{"id" => "x", "label" => "X", "type_ref" => nil, "input_values" => []}],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => [
          %{"id" => "r1", "input_entries" => [~s|"a"|], "output_entries" => ["1"]}
        ]
      }

      result = verify_table(table)

      assert reasons(result) == [:untyped_column]
      assert [%{kind: :incomplete}] = result.findings
    end

    test "a range over an unenumerated string column is an obligation, never a guess" do
      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [%{"id" => "x", "label" => "X", "type_ref" => "string", "input_values" => []}],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => [
          %{"id" => "r1", "input_entries" => [">= \"a\""], "output_entries" => ["1"]},
          %{"id" => "r2", "input_entries" => ["<= \"z\""], "output_entries" => ["2"]}
        ]
      }

      result = verify_table(table)

      # two ranges over an unordered-for-us column: an overlap is conceivable,
      # so nothing is claimed in either direction
      assert reasons(result) == [:opaque_entry, :opaque_entry]
      assert result.findings == []
    end

    test "a product past the region cap yields an obligation, not findings" do
      values = Enum.map(1..400, &to_string/1)
      input = %{"id" => "a", "label" => "A", "type_ref" => "string", "input_values" => values}

      rules =
        Enum.map(values, fn value ->
          cell = ~s|"#{value}"|

          %{"id" => "r_" <> value, "input_entries" => [cell, cell], "output_entries" => ["1"]}
        end)

      table = %{
        "id" => "d",
        "logic" => "decisionTable",
        "hit_policy" => "UNIQUE",
        "inputs" => [input, Map.put(input, "id", "b")],
        "outputs" => [%{"id" => "o1", "label" => "out", "default_output_entry" => nil}],
        "rules" => rules
      }

      # 400 mentioned points + the other region, in each of two columns
      result = verify_table(table)

      assert reasons(result) == [:region_cap]
      obligation = hd(result.obligations)
      assert obligation.detail["cap"] == AshDecisions.Config.verification_max_regions()
      assert obligation.detail["regions"] > obligation.detail["cap"]
    end

    test "obligations are json-serializable maps underneath" do
      result = verify_xml("verification_opaque")

      {:ok, _} = Jason.encode(result.obligations)
      {:ok, _} = Jason.encode(result.findings)
    end
  end

  describe "the result shape" do
    test "verify/1 returns the designed envelope" do
      result = verify_xml("verification_enum")

      assert %{findings: [], obligations: [], verified_at: %DateTime{}, verifier_version: v} =
               result

      assert Regex.match?(~r/^\d+\.\d+/, v)
    end

    test "a graph mixing a table and a literal expression analyses only the table" do
      {:ok, graph} = Compiler.compile(fixture("drd"))
      result = Verifier.verify(graph)

      # `decision_offer` is a literal expression: no findings or obligations may
      # name it. `decision_eligible` is a FIRST table whose second rule is a
      # wildcard, so the only proof available is its legal overlap.
      assert [%{kind: :overlap, severity: :info, path: "rule_adult"}] = result.findings
      assert result.obligations == []
    end

    test "to_storage/1 is the JSON round trip that lands in the column" do
      result = verify_xml("verification_overlap")
      stored = Verifier.to_storage(result)

      assert %{"obligations" => [], "verified_at" => at, "verifier_version" => _} = stored

      finding = Enum.find(stored["findings"], &(&1["kind"] == "overlap"))

      assert finding["severity"] == "error"
      assert finding["stage"] == "completeness"
      assert finding["path"] == "rule_gold_large"
      assert is_map(finding["detail"])
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T/, at)

      assert Jason.decode!(Jason.encode!(stored)) == stored
    end

    test "a decision that is not a decision table is skipped without complaint" do
      result =
        Verifier.verify(%{
          "decisions" => %{
            "d" => %{"id" => "d", "logic" => "literalExpression", "expression" => "1 + 1"}
          },
          "decision_order" => ["d"]
        })

      assert result.findings == []
      assert result.obligations == []
    end
  end
end

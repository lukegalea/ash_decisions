# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshDecisions.Verification.DecisionTable do
  @moduledoc """
  Overlap and completeness analysis for one compiled decision table.

  This is the pure heart of publish-time verification. It takes one decision's
  snapshot from the compiled `graph` — hit policy, input clauses, and the FEEL
  source text of every input entry — and returns what it **proved** as findings
  and what it **could not decide** as obligations. It talks to no engine, no
  database and no clock, which is what makes it testable against a plain map.

  ## How overlap and completeness are decided

  Every input entry is lowered to a constraint by
  `AshDecisions.Verification.Constraint`. Each column's domain is then cut into
  a finite set of **regions** on which every constraint is constant:

    * an enumerated column (`inputValues`, or `boolean`) — one region per value;
    * a numeric column (`number`) — the elementary intervals between every bound
      any rule mentions, plus a singleton per bound;
    * a column with no declared domain — one region per point any rule mentions,
      plus one *other* region for everything else.

  Overlap and completeness are then set algebra over the product of those
  regions: two rules overlap iff some region is matched by both; a gap is a
  region matched by no rule (and no default output entry). Every membership
  answer is `:yes`, `:no` or `:unknown`, and `:unknown` is contagious in exactly
  one direction — it can *block* a clean bill of health (which then becomes an
  obligation) but it can never manufacture a finding. A finding exists only
  where a witness region was actually constructed. That is the soundness rule
  from the recognizer, kept all the way through: the verifier never narrows.

  The product is bounded before it is built:
  `AshDecisions.Config.verification_max_regions/0`. A table over the cap yields
  a `:region_cap` obligation rather than findings.

  ## What is deliberately not decided

  Ranges over strings are decidable in principle (the engine orders them
  lexicographically) and are deliberately not attempted: nobody writes them, and
  the FEEL lexicographic order is a place to be wrong quietly. A string column
  is decided on points and negated points only; a range in such a column becomes
  an obligation, never a guess. The same is true of a range with non-numeric
  endpoints in a numeric column, and of any cell the recognizer lowered to
  `{:opaque, _}`.
  """

  alias AshDecisions.Config
  alias AshDecisions.Feel
  alias AshDecisions.Verification.Constraint
  alias AshDecisions.Verification.Finding
  alias AshDecisions.Verification.Obligation

  @typedoc """
  One elementary region of a column's domain.

    * `{:atom, value}` — the single value `value` (an enumerated value, or a
      point some rule mentions);
    * `{:interval, lo, hi, rep}` — the numeric interval between bounds `lo` and
      `hi` (each `{:incl, d}`, `{:excl, d}` or `:unbounded`), with `rep` a
      concrete member kept for witnesses;
    * `:other` — any value other than the points the column's rules mention.
  """
  @type region ::
          {:atom, term()}
          | {:interval, Constraint.bound(), Constraint.bound(), Decimal.t() | nil}
          | :other

  @type verdict :: :yes | :no | :unknown

  @typedoc "One input column: its declared domain and the regions cut from it."
  @type column :: %{
          required(:id) => String.t() | nil,
          required(:label) => String.t(),
          required(:kind) => :enum | :number | :points,
          required(:values) => [term()],
          required(:points) => [term()],
          required(:untyped?) => boolean(),
          required(:regions) => [region()]
        }

  # A gap list caps what goes into the finding's `detail`; the count is honest
  # even when the listing is not exhaustive, and the region cap already bounds
  # how large that count can get.
  @max_listed_gaps 20

  @doc """
  Analyses one decision's snapshot.

  Returns `{findings, obligations}`. A decision whose logic is not a decision
  table has nothing to analyse — a literal expression has no input space, and
  the compiler already proved its expression parses.
  """
  @spec analyze(map()) :: {[Finding.t()], [Obligation.t()]}
  def analyze(decision) when is_map(decision) do
    case decision["logic"] do
      "decisionTable" -> analyze_table(decision)
      _ -> {[], []}
    end
  end

  # -- the analysis -----------------------------------------------------------

  defp analyze_table(decision) do
    table_id = decision["id"] || decision["name"] || "decision"
    inputs = decision["inputs"] || []
    rules = decision["rules"] || []
    outputs = decision["outputs"] || []
    policy = decision["hit_policy"]

    {cells, parse_findings} = lower_entries(inputs, rules, table_id)

    if parse_findings != [] do
      # Stage one failed: at least one cell does not parse, and the engine will
      # fail on it every time its row is reached. Nothing built on top of the
      # cells means anything yet, so the parse findings are the whole answer.
      {parse_findings, []}
    else
      columns = Enum.map(Enum.with_index(inputs), fn {input, i} -> column(input, cells, i) end)
      run(columns, cells, rules, outputs, policy, table_id)
    end
  end

  defp run(columns, cells, rules, outputs, policy, table_id) do
    obligations =
      column_obligations(columns) ++
        cell_obligations(columns, cells, rules) ++
        policy_obligation(policy, table_id)

    region_total = Enum.reduce(columns, 1, fn column, n -> n * length(column.regions) end)
    cap = Config.verification_max_regions()

    if region_total > cap do
      cap_obligation =
        obligation(
          :region_cap,
          table_id,
          "the table's input space is #{region_total} regions, past the analysis cap of " <>
            "#{cap}; overlap and completeness were not decided",
          %{"regions" => region_total, "cap" => cap}
        )

      {[], obligations ++ [cap_obligation]}
    else
      regions = cross_product(Enum.map(columns, & &1.regions))
      verdicts = verdicts(cells, regions)
      findings = table_findings(verdicts, rules, regions, columns, outputs, policy, table_id)

      {findings, obligations}
    end
  end

  # -- stage one: lower every input entry -------------------------------------

  # Mirrors the engine's `Enum.zip(input_entries, input_values)`: a rule with
  # more entries than columns has the extras ignored, and one with fewer has the
  # missing cells impose nothing.
  defp lower_entries(inputs, rules, table_id) do
    width = length(inputs)

    Enum.map_reduce(rules, [], fn rule, findings ->
      rule_id = rule["id"] || table_id
      entries = rule["input_entries"] || []

      {cells, rule_findings} =
        Enum.map_reduce(0..(width - 1)//1, findings, fn index, acc ->
          lower_cell(entries, inputs, rule_id, index, acc)
        end)

      {cells, Enum.reverse(rule_findings)}
    end)
  end

  defp lower_cell(entries, inputs, rule_id, index, acc) do
    text = Enum.at(entries, index)

    case Constraint.lower(text) do
      {:ok, constraint} ->
        {%{text: text || "", constraint: constraint}, acc}

      {:error, failure} ->
        input = Enum.at(inputs, index) || %{}
        cell = %{text: text || "", constraint: {:opaque, text || ""}}

        {cell, [parse_finding(rule_id, index, input, text, failure) | acc]}
    end
  end

  defp parse_finding(rule_id, index, input, text, failure) do
    label = column_label(input, index)

    finding(
      :malformed_entry,
      :error,
      rule_id,
      "input entry #{index + 1} (#{label}) does not parse, and the engine will fail on " <>
        "it every time this rule is reached: #{failure.message}",
      %{
        "column" => input["id"],
        "column_label" => label,
        "entry_index" => index,
        "entry" => text || "",
        "part" => failure.part,
        "offset" => failure.offset
      },
      :parse
    )
  end

  # -- columns and their regions ----------------------------------------------

  defp column(input, cells, index) do
    values = input["input_values"] || []
    type_ref = input["type_ref"] && String.downcase(input["type_ref"])
    constraints = Enum.map(cells, fn row -> Enum.at(row, index).constraint end)

    cond do
      values != [] ->
        build_column(input, index, :enum, values, constraints)

      type_ref == "boolean" ->
        build_column(input, index, :enum, [true, false], constraints)

      type_ref in ["number", "integer"] ->
        build_column(input, index, :number, [], constraints)

      true ->
        built = build_column(input, index, :points, [], constraints)
        %{built | points: mentioned_points(constraints)}
    end
  end

  defp build_column(input, index, kind, values, constraints) do
    %{
      id: input["id"],
      label: column_label(input, index),
      kind: kind,
      values: values,
      points: [],
      untyped?: is_nil(input["type_ref"]) and values == [],
      regions: regions(kind, values, constraints)
    }
  end

  defp regions(:enum, values, _cells), do: Enum.map(values, &{:atom, &1})

  defp regions(:number, _values, cells) do
    cuts =
      cells
      |> Enum.flat_map(&cut_values/1)
      |> sort_cuts()

    case cuts do
      [] ->
        [{:interval, :unbounded, :unbounded, Decimal.new(0)}]

      cuts ->
        first = hd(cuts)
        final = List.last(cuts)

        head = [{:interval, :unbounded, {:excl, first}, below(first)}]
        tail = [{:interval, {:excl, final}, :unbounded, above(final)}]

        head ++ middle_regions(cuts) ++ tail
    end
  end

  defp regions(:points, _values, cells) do
    Enum.map(mentioned_points(cells), &{:atom, &1}) ++ [:other]
  end

  defp middle_regions([_only]), do: []

  defp middle_regions([a, b | rest]) do
    singleton = {:interval, {:incl, a}, {:incl, a}, a}
    open = {:interval, {:excl, a}, {:excl, b}, midpoint(a, b)}
    [singleton, open | middle_regions([b | rest])]
  end

  defp cut_values({:point, %Decimal{} = value}), do: [value]
  defp cut_values({:range, lo, hi}), do: bound_value(lo) ++ bound_value(hi)
  defp cut_values({:not, [inner]}), do: cut_values(inner)
  defp cut_values({:union, constraints}), do: Enum.flat_map(constraints, &cut_values/1)
  defp cut_values(_), do: []

  defp bound_value({:incl, %Decimal{} = value}), do: [value]
  defp bound_value({:excl, %Decimal{} = value}), do: [value]
  defp bound_value(_), do: []

  # Sort and deduplicate numerically: `1` and `1.0` are one cut, not two.
  defp sort_cuts(cuts) do
    cuts
    |> Enum.sort(&Decimal.lt?/2)
    |> Enum.dedup_by(fn value -> value |> Decimal.normalize() |> Decimal.to_string() end)
  end

  defp below(%Decimal{} = value), do: Decimal.sub(value, Decimal.new(1))
  defp above(%Decimal{} = value), do: Decimal.add(value, Decimal.new(1))

  defp midpoint(a, b), do: a |> Decimal.add(b) |> Decimal.div(Decimal.new(2))

  defp mentioned_points(cells) do
    cells
    |> Enum.flat_map(&point_values/1)
    |> Enum.uniq_by(&point_key/1)
  end

  defp point_values({:point, value}), do: [value]
  defp point_values({:not, [inner]}), do: point_values(inner)
  defp point_values({:union, constraints}), do: Enum.flat_map(constraints, &point_values/1)
  defp point_values(_), do: []

  # `1` and `1.0` are the same point.
  defp point_key(%Decimal{} = value),
    do: {:number, Decimal.normalize(value) |> Decimal.to_string()}

  defp point_key(value), do: {typeof(value), value}

  defp typeof(value) when is_binary(value), do: :string
  defp typeof(value) when is_boolean(value), do: :boolean
  defp typeof(value) when is_nil(value), do: :null
  defp typeof(_), do: :other

  # -- membership: three-valued, and unknown can only block, never claim ------

  defp matches?(:any, _region), do: :yes
  defp matches?({:opaque, _}, _region), do: :unknown

  defp matches?({:union, constraints}, region) do
    results = Enum.map(constraints, &matches?(&1, region))

    cond do
      :yes in results -> :yes
      :unknown in results -> :unknown
      true -> :no
    end
  end

  defp matches?({:not, [inner]}, region) do
    case matches?(inner, region) do
      :yes -> :no
      :no -> :yes
      :unknown -> :unknown
    end
  end

  defp matches?({:point, value}, {:atom, other}), do: from_bool(equal?(value, other))

  # A point is one of the column's mentioned values by construction, so it is
  # never in the *other* region.
  defp matches?({:point, _value}, :other), do: :no

  # Every point in a numeric column is a cut, so a point can only meet the
  # singleton region cut at itself — never the open interval beside it.
  defp matches?({:point, value}, {:interval, {:incl, a}, {:incl, b}, _rep}) do
    from_bool(equal?(value, a) and equal?(a, b))
  end

  defp matches?({:point, _value}, {:interval, _lo, _hi, _rep}), do: :no

  defp matches?({:range, _lo, _hi} = range, {:atom, value}), do: contains?(range, value)

  defp matches?({:range, lo, hi}, {:interval, rlo, rhi, _rep}) do
    cond do
      interval_within?(rlo, rhi, lo, hi) -> :yes
      interval_disjoint?(rlo, rhi, lo, hi) -> :no
      true -> :unknown
    end
  end

  # A range over an unenumerated, unordered column: the design deliberately does
  # not attempt the FEEL lexicographic order.
  defp matches?({:range, _lo, _hi}, :other), do: :unknown

  defp contains?({:range, lo, hi}, value) do
    with :yes <- bound_allows_lower(lo, value) do
      bound_allows_upper(hi, value)
    end
  end

  defp bound_allows_lower(:unbounded, _value), do: :yes
  defp bound_allows_lower({:incl, bound}, value), do: from_cmp(cmp(value, bound), [:gt, :eq])
  defp bound_allows_lower({:excl, bound}, value), do: from_cmp(cmp(value, bound), [:gt])
  defp bound_allows_upper(:unbounded, _value), do: :yes
  defp bound_allows_upper({:incl, bound}, value), do: from_cmp(cmp(value, bound), [:lt, :eq])
  defp bound_allows_upper({:excl, bound}, value), do: from_cmp(cmp(value, bound), [:lt])

  # Equality is total even across types: FEEL never calls `"gold"` and `42`
  # equal, so a point of one type provably misses a region of another.
  defp equal?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  defp equal?(a, b), do: a == b

  # Ordering, by contrast, only exists between numbers here; anything else is
  # not a `:no`, it is an *unknown*.
  defp cmp(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b)
  defp cmp(_, _), do: :incomparable

  defp from_bool(true), do: :yes
  defp from_bool(false), do: :no

  defp from_cmp(:incomparable, _allowed), do: :unknown
  defp from_cmp(result, allowed), do: from_bool(result in allowed)

  # -- interval algebra --------------------------------------------------------

  # Does every value of the region interval satisfy the range's bound?
  defp lower_ok?(_region_lo, :unbounded), do: true
  defp lower_ok?(:unbounded, _range_lo), do: false
  defp lower_ok?({:incl, u}, {:incl, v}), do: cmp(u, v) in [:gt, :eq]
  defp lower_ok?({:excl, u}, {:incl, v}), do: cmp(u, v) in [:gt, :eq]
  defp lower_ok?({:incl, u}, {:excl, v}), do: cmp(u, v) == :gt
  defp lower_ok?({:excl, u}, {:excl, v}), do: cmp(u, v) in [:gt, :eq]

  defp upper_ok?(_region_hi, :unbounded), do: true
  defp upper_ok?(:unbounded, _range_hi), do: false
  defp upper_ok?({:incl, u}, {:incl, v}), do: cmp(u, v) in [:lt, :eq]
  defp upper_ok?({:excl, u}, {:incl, v}), do: cmp(u, v) in [:lt, :eq]
  defp upper_ok?({:incl, u}, {:excl, v}), do: cmp(u, v) == :lt
  defp upper_ok?({:excl, u}, {:excl, v}), do: cmp(u, v) in [:lt, :eq]

  defp interval_within?(rlo, rhi, lo, hi), do: lower_ok?(rlo, lo) and upper_ok?(rhi, hi)

  # The region interval and the range share no value. An incomparable pair
  # reports false here as well as in `interval_within?/4`, so the caller sees
  # neither "within" nor "disjoint" and answers `:unknown`.
  defp interval_disjoint?(rlo, rhi, lo, hi) do
    entirely_below?(rhi, lo) or entirely_above?(rlo, hi)
  end

  defp entirely_below?(_rhi, :unbounded), do: false
  defp entirely_below?(:unbounded, _range_lo), do: false
  defp entirely_below?({:incl, u}, {:incl, v}), do: cmp(u, v) == :lt
  defp entirely_below?({:excl, u}, {:incl, v}), do: cmp(u, v) in [:lt, :eq]
  defp entirely_below?({:incl, u}, {:excl, v}), do: cmp(u, v) in [:lt, :eq]
  defp entirely_below?({:excl, u}, {:excl, v}), do: cmp(u, v) in [:lt, :eq]

  defp entirely_above?(_rlo, :unbounded), do: false
  defp entirely_above?(:unbounded, _range_hi), do: false
  defp entirely_above?({:incl, u}, {:incl, v}), do: cmp(u, v) == :gt
  defp entirely_above?({:excl, u}, {:incl, v}), do: cmp(u, v) in [:gt, :eq]
  defp entirely_above?({:incl, u}, {:excl, v}), do: cmp(u, v) in [:gt, :eq]
  defp entirely_above?({:excl, u}, {:excl, v}), do: cmp(u, v) in [:gt, :eq]

  # -- the verdict grid ---------------------------------------------------------

  defp cross_product([first | rest]) do
    Enum.reduce(rest, Enum.map(first, &[&1]), fn column_regions, acc ->
      for region <- column_regions, prefix <- acc do
        prefix ++ [region]
      end
    end)
  end

  defp cross_product([]), do: [[]]

  defp verdicts(cells, regions) do
    Enum.map(cells, fn row -> Enum.map(regions, &row_verdict(row, &1)) end)
  end

  defp row_verdict(row, region) do
    row
    |> Enum.zip(region)
    |> Enum.map(fn {cell, column_region} -> matches?(cell.constraint, column_region) end)
    |> and_all()
  end

  defp and_all(verdicts) do
    cond do
      :no in verdicts -> :no
      :unknown in verdicts -> :unknown
      true -> :yes
    end
  end

  # -- findings and obligations -------------------------------------------------

  defp table_findings(verdicts, rules, regions, columns, outputs, policy, table_id) do
    overlap_findings(verdicts, rules, regions, columns, policy) ++
      unsatisfiable_findings(verdicts, rules) ++
      shadowed_findings(verdicts, rules, policy) ++
      incomplete_finding(verdicts, regions, columns, outputs, policy, table_id)
  end

  defp overlap_findings(verdicts, rules, regions, columns, policy) do
    if policy == "COLLECT" do
      # Overlap is the design of a COLLECT table, not a defect in it; the
      # :hit_policy obligation already says nothing was proved here.
      []
    else
      count = length(rules)
      indexes = 0..(count - 1)//1

      for i <- indexes,
          j <- indexes,
          i < j,
          witness = first_both_yes(verdicts, i, j, regions, columns),
          witness != nil do
        overlap_finding(Enum.at(rules, i), Enum.at(rules, j), witness, policy)
      end
    end
  end

  defp first_both_yes(verdicts, i, j, regions, columns) do
    row_i = Enum.at(verdicts, i)
    row_j = Enum.at(verdicts, j)

    found =
      regions
      |> Enum.with_index()
      |> Enum.find_index(fn {_region, index} ->
        Enum.at(row_i, index) == :yes and Enum.at(row_j, index) == :yes
      end)

    case found do
      nil -> nil
      index -> %{index: index, region: Enum.at(regions, index), columns: columns}
    end
  end

  defp overlap_finding(rule_i, rule_j, witness, policy) do
    ids = [rule_id(rule_i), rule_id(rule_j)]
    description = region_description(witness.region, witness.columns)

    severity =
      case policy do
        "UNIQUE" -> :error
        "ANY" -> if outputs_equal?(rule_i, rule_j), do: :info, else: :error
        _ -> :info
      end

    message =
      case {policy, severity} do
        {"UNIQUE", _} ->
          "rules #{join(ids)} can both match the same input, which UNIQUE refuses: " <>
            "witness region #{description}"

        {"ANY", :error} ->
          "rules #{join(ids)} can both match the same input and their output entries " <>
            "differ, so which one decides is accidental: witness region #{description}"

        _ ->
          "rules #{join(ids)} can both match the same input (legal under #{policy}): " <>
            "witness region #{description}"
      end

    finding(
      :overlap,
      severity,
      Enum.at(ids, 0),
      message,
      %{
        "rules" => ids,
        "region" => description,
        "columns" => column_descriptions(witness.region, witness.columns)
      },
      :completeness
    )
  end

  defp outputs_equal?(rule_i, rule_j),
    do: (rule_i["output_entries"] || []) == (rule_j["output_entries"] || [])

  defp unsatisfiable_findings(verdicts, rules) do
    rules
    |> Enum.with_index()
    |> Enum.filter(fn {_rule, index} ->
      row = Enum.at(verdicts, index)
      row != [] and :yes not in row and :unknown not in row
    end)
    |> Enum.map(fn {rule, _index} ->
      id = rule_id(rule)

      finding(
        :unsatisfiable,
        :error,
        id,
        "rule '#{id}' can never fire: its entries contradict the declared input space, " <>
          "so it is dead text in a document an auditor reads as law",
        %{"rule" => id},
        :completeness
      )
    end)
  end

  defp shadowed_findings(verdicts, rules, "FIRST") do
    count = length(rules)

    for j <- 1..(count - 1)//1,
        subsumer = subsumed_by(verdicts, j),
        subsumer != nil do
      rule = Enum.at(rules, j)
      earlier = Enum.at(rules, subsumer)
      id = rule_id(rule)

      finding(
        :shadowed,
        :warning,
        id,
        "rule '#{id}' can only fire where rule '#{rule_id(earlier)}' has already fired, " <>
          "and FIRST takes the earlier one; the rule is unreachable",
        %{"rule" => id, "subsumed_by" => rule_id(earlier)},
        :completeness
      )
    end
  end

  defp shadowed_findings(_verdicts, _rules, _policy), do: []

  defp subsumed_by(verdicts, j) do
    later = Enum.at(verdicts, j)

    if :yes in later do
      find_subsumer(verdicts, j, later)
    end
  end

  defp find_subsumer(verdicts, j, later) do
    0..(j - 1)//1
    |> Enum.find(fn i -> covers_all?(Enum.at(verdicts, i), later) end)
  end

  # Rule i covers rule j when i matches every region j matches. Regions where j
  # is unknown are skipped, not assumed: subsumption must be proved over the
  # whole space or not claimed.
  defp covers_all?(earlier, later) do
    later
    |> Enum.with_index()
    |> Enum.all?(fn
      {:yes, index} -> Enum.at(earlier, index) == :yes
      _other -> true
    end)
  end

  defp incomplete_finding(verdicts, regions, columns, outputs, policy, table_id) do
    if all_outputs_have_defaults?(outputs) do
      []
    else
      regions
      |> uncovered_regions(verdicts)
      |> case do
        [] ->
          []

        gaps ->
          [gap_finding(gaps, columns, policy, table_id)]
      end
    end
  end

  defp uncovered_regions(regions, verdicts) do
    regions
    |> Enum.with_index()
    |> Enum.filter(fn {_region, index} ->
      Enum.all?(verdicts, fn row -> Enum.at(row, index) == :no end)
    end)
  end

  defp gap_finding(gaps, columns, policy, table_id) do
    total = length(gaps)

    listed =
      gaps
      |> Enum.take(@max_listed_gaps)
      |> Enum.map(fn {region, _index} ->
        %{"region" => region_description(region, columns), "witness" => witness(region, columns)}
      end)

    finding(
      :incomplete,
      incomplete_severity(policy),
      table_id,
      "#{total} region(s) of the input space match no rule and there is no default " <>
        "output entry, so the table answers null there; for example, " <>
        hd(listed)["region"],
      %{"gap_count" => total, "gaps" => listed},
      :completeness
    )
  end

  # The engine applies default outputs only when *every* output clause carries
  # one, and answers null otherwise — so only that case covers a gap.
  defp all_outputs_have_defaults?(outputs) do
    outputs != [] and
      Enum.all?(outputs, fn output -> is_binary(output["default_output_entry"]) end)
  end

  defp incomplete_severity("COLLECT"), do: :info

  defp incomplete_severity(_policy),
    do: if(Config.incomplete_tables() == :error, do: :error, else: :warning)

  # -- obligations --------------------------------------------------------------

  defp column_obligations(columns) do
    for column <- columns, column.untyped? do
      obligation(
        :untyped_column,
        column.id || column.label,
        "input '#{column.label}' has no typeRef and no inputValues, so no domain is " <>
          "declared; the analysis fell back to the values the rules themselves mention",
        %{"column" => column.id, "label" => column.label}
      )
    end
  end

  # A cell that is `:unknown` somewhere in its own column is a cell the analysis
  # did not decide — an `:opaque` construct, or a range where no order was
  # declared. Each one is an obligation: it is why the surrounding conclusions
  # stop where they do.
  defp cell_obligations(columns, cells, rules) do
    columns
    |> Enum.with_index()
    |> Enum.flat_map(fn {column, index} ->
      cells
      |> Enum.with_index()
      |> Enum.flat_map(&undecidable_obligation(&1, rules, column, index))
    end)
  end

  defp undecidable_obligation({row, rule_index}, rules, column, index) do
    cell = Enum.at(row, index)
    id = rules |> Enum.at(rule_index) |> rule_id()

    if undecidable_here?(cell.constraint, column.regions) do
      [
        obligation(
          :opaque_entry,
          id,
          "input entry #{index + 1} of rule '#{id}' (#{cell.text}) was not decided: " <>
            why_undecidable(cell.constraint),
          %{"column" => column.id, "column_label" => column.label, "entry" => cell.text}
        )
      ]
    else
      []
    end
  end

  defp undecidable_here?(constraint, regions) do
    Enum.any?(regions, &(matches?(constraint, &1) == :unknown))
  end

  defp why_undecidable({:opaque, _text}),
    do: "it uses a FEEL construct the recognizer does not lower"

  defp why_undecidable({:range, _lo, _hi}),
    do: "it is a range, and ranges are decided only over numeric columns"

  defp why_undecidable(_constraint),
    do: "no ordering was declared for the values it compares"

  defp policy_obligation("COLLECT", table_id) do
    [
      obligation(
        :hit_policy,
        table_id,
        "COLLECT gathers every matching rule, so overlapping rules are legal and " <>
          "overlap was not analysed",
        %{"hit_policy" => "COLLECT"}
      )
    ]
  end

  defp policy_obligation(_policy, _table_id), do: []

  # -- describing regions, for humans and for JSON -----------------------------

  defp region_description(regions, columns) do
    regions
    |> Enum.zip(columns)
    |> Enum.map_join(" and ", fn {region, column} -> describe_region(region, column) end)
  end

  defp column_descriptions(regions, columns) do
    regions
    |> Enum.zip(columns)
    |> Map.new(fn {region, column} ->
      {column.id || column.label, describe_region(region, column)}
    end)
  end

  defp describe_region({:atom, value}, column), do: "#{column.label} is #{Feel.print(value)}"

  defp describe_region(:other, column) do
    case column.points do
      [] ->
        "#{column.label} is any value"

      points ->
        rendered = Enum.map_join(points, ", ", &Feel.print/1)
        "#{column.label} is a value other than #{rendered}"
    end
  end

  defp describe_region({:interval, :unbounded, :unbounded, _rep}, column),
    do: "#{column.label} is any number"

  defp describe_region({:interval, lo, :unbounded, _rep}, column),
    do: "#{column.label} #{lower_op(lo)}"

  defp describe_region({:interval, :unbounded, hi, _rep}, column),
    do: "#{column.label} #{upper_op(hi)}"

  defp describe_region({:interval, lo, hi, _rep}, column) do
    "#{column.label} in #{open_bracket(lo)}#{bound_text(lo)}..#{bound_text(hi)}" <>
      "#{close_bracket(hi)}"
  end

  defp lower_op({:incl, value}), do: ">= #{Feel.print(value)}"
  defp lower_op({:excl, value}), do: "> #{Feel.print(value)}"
  defp upper_op({:incl, value}), do: "<= #{Feel.print(value)}"
  defp upper_op({:excl, value}), do: "< #{Feel.print(value)}"

  defp open_bracket({:incl, _value}), do: "["
  defp open_bracket(_other), do: "("
  defp close_bracket({:incl, _value}), do: "]"
  defp close_bracket(_other), do: ")"

  defp bound_text({:incl, value}), do: Feel.print(value)
  defp bound_text({:excl, value}), do: Feel.print(value)
  defp bound_text(:unbounded), do: "unbounded"

  defp witness(regions, columns) do
    regions
    |> Enum.zip(columns)
    |> Map.new(fn {region, column} ->
      {column.id || column.label, witness_value(region)}
    end)
  end

  defp witness_value({:atom, value}), do: Feel.print(value)
  defp witness_value({:interval, _lo, _hi, rep}), do: rep && Feel.print(rep)
  defp witness_value(:other), do: nil

  defp column_label(input, index) do
    input["label"] || input["name"] || "column #{index + 1}"
  end

  defp rule_id(rule), do: rule["id"] || "unnamed rule"

  defp join(ids), do: Enum.map_join(ids, " and ", fn id -> "'#{id}'" end)

  defp finding(kind, severity, path, message, detail, stage) do
    %Finding{
      kind: kind,
      severity: severity,
      path: path || "unknown",
      message: message,
      detail: detail,
      stage: stage
    }
  end

  defp obligation(reason, path, message, detail) do
    %Obligation{reason: reason, path: path || "unknown", message: message, detail: detail}
  end
end

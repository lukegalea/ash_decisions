defmodule AshDecisions.Compiler do
  @moduledoc """
  Compiles a DMN document into an immutable, verified snapshot.

  `compile/1` returns `{:ok, graph}` or `{:error, [%{path: _, message: _}]}`,
  where `path` is the id of the offending DMN element. That shape is what
  `AshDecisions.Resources.Definition` stores in its `errors` column and refuses
  to publish over.

  Three things happen, in order:

    1. **The engine loads and validates the document.** `Boxic.DMN.load_xml/1`
       then `Boxic.DMN.validate/1` — the same pair the conformance harness uses,
       so a document this package accepts is a document the reported 97.68% was
       measured against.
    2. **The unsupported subset is refused**, by element id. See below.
    3. **A snapshot is built** from the XML directly, with
       `AshDecisions.Tck.Xml`, which already handles the namespace and UTF-8
       problems that make naive DMN parsing wrong.

  ## Why an unsupported construct is an error and not a shrug

  A DMN document is drawn by a business analyst and then executed by this
  application, and the entire value of that arrangement rests on the diagram and
  the system being about the same decision. An element the compiler skips
  silently is the exact mechanism by which they stop being: the analyst adds a
  boxed context, sees it in the designer, and the running system quietly decides
  as though it were not there. Nobody is told. The two artefacts diverge, and
  they diverge in the direction of the analyst believing something that is false.

  So the compiler refuses. `ash_bpmn`'s graph compiler takes the same posture
  toward BPMN elements outside its executable subset, for the same reason.

  ### What is refused

    * **Boxed expressions other than `decisionTable` and `literalExpression`** —
      `context`, `invocation`, `relation`, `functionDefinition`, `list`, and the
      DMN 1.5 additions (`conditional`, `filter`, `for`, `every`, `some`). These
      are supportable and simply are not supported yet; the error says which one
      and where.
    * **`businessKnowledgeModel` and `decisionService`** — invocable units this
      package does not evaluate, together with the `knowledgeRequirement` edges
      that point at them.
    * **The `OUTPUT ORDER` and `RULE ORDER` hit policies.** Not a gap: both make
      the *ordering* of the result list semantically significant, so the answer
      depends on where a rule sits in the document rather than on what the rule
      says. That is a decision whose meaning changes when someone drags a row,
      and a versioned, auditable rule store is the wrong place for one. The
      implemented policies are `UNIQUE`, `ANY`, `FIRST`, `PRIORITY` and `COLLECT`
      with its aggregators, all of which give an answer that does not depend on
      rule sequence.
    * **An `aggregation` on a table that is not `COLLECT`**, because DMN gives it
      no meaning there and the engine will ignore it — which is the silent
      divergence again, in miniature.
    * **Unresolvable `informationRequirement` references, and cycles.** A DRD
      whose decisions require each other in a loop has no evaluation order.

  Multi-decision DRDs joined by `informationRequirement` edges are supported, and
  are the normal case.

  ## What the snapshot contains, and what it deliberately does not

  The graph is a plain JSON-able map: the decisions in document order, their
  names, their requirement edges, hit policies, input and output clauses, and the
  FEEL **source text** of every expression.

  Not a parsed AST. Boxic's AST is tagged tuples containing `Decimal` structs —
  expressive, not JSON, and carrying no version tag of its own. A compiled
  expression lives inside a `Definition.graph` snapshot, and a caller holding a
  published definition has to keep evaluating it across an upgrade of the engine
  underneath. A tuple tree whose shape may change between releases cannot survive
  that; source text can. So the snapshot records the text plus the engine version
  that validated it at publish time, and evaluation re-parses through the
  memoised cache in `AshDecisions.Feel`.

  Every expression that is a plain FEEL expression is parsed here, so a document
  that compiles is a document whose expressions are known to parse, to be within
  the size bound and within the depth bound. Decision table **input entries** are
  the exception: they are unary tests, a separate grammar that Boxic parses
  inside its evaluator rather than exposing a parser for, so they are size-bounded
  here and validated when they first run. That limit is stated rather than
  papered over.
  """

  alias AshDecisions.Tck.Xml

  @supported_logic ~w(decisionTable literalExpression)

  # Every boxed-expression element name DMN 1.5 defines. A decision's "logic" is
  # whichever of its children appears in this list, which is what lets the
  # compiler tell an unsupported boxed expression from an ordinary child like
  # `variable` or `description` rather than guessing from a blocklist.
  @boxed_expressions @supported_logic ++
                       ~w(context invocation relation functionDefinition list
                          conditional filter for every some iterator)

  @refused_hit_policies ~w(OUTPUT_ORDER RULE_ORDER)
  @known_hit_policies ~w(UNIQUE ANY FIRST PRIORITY COLLECT) ++ @refused_hit_policies
  @known_aggregators ~w(SUM COUNT MIN MAX)

  @type error :: %{path: String.t(), message: String.t()}

  @doc """
  Compiles DMN XML into a verified snapshot.

  Returns `{:ok, graph}` or `{:error, [%{path: _, message: _}]}`. Errors are
  accumulated rather than returned one at a time, so an author fixing a document
  sees everything wrong with it in one pass.
  """
  @spec compile(String.t()) :: {:ok, map()} | {:error, [error()]}
  def compile(xml) when is_binary(xml) do
    # Our own refusals run before the engine's validator, not after it. Boxic
    # catches several of the same problems -- a dangling `requiredDecision`, an
    # `aggregation` outside COLLECT -- and reports them as a diagnostic code
    # against a generic message, which is correct and tells the author almost
    # nothing. Going first means the author gets the sentence that names the
    # element and says what to do about it, and the engine's validator still
    # runs on everything we let through.
    with {:ok, root} <- parse(xml) do
      case refusals(root) ++ reference_errors(root) do
        [] ->
          with {:ok, _model} <- load_and_validate(xml), do: build(root)

        errors ->
          {:error, errors}
      end
    end
  end

  @doc """
  Compiles DMN XML, raising on failure with the errors formatted.
  """
  @spec compile!(String.t()) :: map()
  def compile!(xml) do
    case compile(xml) do
      {:ok, graph} -> graph
      {:error, errors} -> raise "DMN compilation failed:\n" <> format_errors(errors)
    end
  end

  @doc "Renders an error list the way `compile!/1` does."
  @spec format_errors([error()]) :: String.t()
  def format_errors(errors) do
    Enum.map_join(errors, "\n", fn %{path: path, message: message} -> "  [#{path}] #{message}" end)
  end

  # -- the engine's own load and validate ------------------------------------

  # `validate/1` rather than `validate(model, for: :evaluation)`. The two-arity
  # form additionally requires the document to be in the DMN 1.5 profile and
  # replaces every message with one generic sentence; the corpus this engine was
  # measured against spans DMN 1.2 to 1.5, and so does everything dmn-js exports.
  # Refusing a 1.3 document would refuse most real ones.
  defp load_and_validate(xml) do
    # Same normalization the evaluator applies, for the same reason: a document that
    # compiles must be a document that runs, so both must see the engine the same way.
    case xml |> AshDecisions.Dmn.Profile.normalize() |> Boxic.DMN.load_xml() do
      {:ok, model} ->
        case Boxic.DMN.validate(model) do
          :ok -> {:ok, model}
          {:error, issues} -> {:error, Enum.map(issues, &validation_error/1)}
        end

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, Enum.map(diagnostics, &validation_error/1)}

      {:error, reason} ->
        {:error, [error("document", "the DMN document could not be loaded: #{render(reason)}")]}
    end
  rescue
    e -> {:error, [error("document", "loading the DMN document raised: #{Exception.message(e)}")]}
  end

  # A diagnostic's `message` is one sentence for every code Boxic emits ("The
  # normalized DMN model is not valid."), so the code and the details are the
  # only informative parts and both belong in the text.
  defp validation_error(%Boxic.DMN.Diagnostic{} = diagnostic) do
    detail =
      case diagnostic.details do
        %{validation_error: issue} -> render(issue)
        nil -> ""
        other -> render(other)
      end

    error(
      diagnostic_path(diagnostic),
      String.trim("the engine rejected the model: #{diagnostic.code} #{detail}")
    )
  end

  # Boxic's one-arity validator returns raw tuples whose first element is the
  # problem and whose remaining elements identify where. That is more informative
  # than the diagnostic form, which is why it is preferred -- but it means the
  # rendering is ours.
  defp validation_error(issue) when is_tuple(issue) do
    [code | rest] = Tuple.to_list(issue)
    path = Enum.find(rest, "model", &is_binary/1)
    error(path, "the engine rejected the model: #{code} #{render(rest)}")
  end

  defp validation_error(issue),
    do: error("model", "the engine rejected the model: #{render(issue)}")

  # Prefer an identifier the author can find in their document over Boxic's
  # positional path (`[:validation, 0]`), which is an index into a list they
  # cannot see.
  defp diagnostic_path(%Boxic.DMN.Diagnostic{details: %{validation_error: issue}})
       when is_tuple(issue) do
    issue |> Tuple.to_list() |> Enum.find(&is_binary/1)
  end

  defp diagnostic_path(%Boxic.DMN.Diagnostic{path: path}), do: Enum.join(path, "/")

  defp parse(xml) do
    case Xml.parse(xml) do
      {:ok, root} ->
        {:ok, root}

      {:error, message} ->
        {:error, [error("document", "the XML could not be parsed: #{message}")]}
    end
  end

  # -- refusals --------------------------------------------------------------

  defp refusals(root) do
    invocable_refusals(root) ++
      Enum.flat_map(decisions(root), &decision_refusals/1)
  end

  defp invocable_refusals(root) do
    Enum.flat_map(
      [
        {"businessKnowledgeModel",
         "business knowledge models are not supported: this package evaluates decisions, " <>
           "not reusable invocable logic"},
        {"decisionService",
         "decision services are not supported: this package evaluates decisions " <>
           "individually, so a service that packages several of them has no meaning here"}
      ],
      fn {name, message} ->
        root |> Xml.descendants(name) |> Enum.map(&error(id_of(&1), message))
      end
    )
  end

  defp decision_refusals(decision) do
    id = id_of(decision)

    knowledge =
      decision
      |> Xml.children("knowledgeRequirement")
      |> Enum.map(fn _ ->
        error(
          id,
          "decision '#{id}' has a knowledgeRequirement; business knowledge models and " <>
            "decision services are not supported, so there is nothing for it to point at"
        )
      end)

    knowledge ++ logic_refusals(decision, id)
  end

  defp logic_refusals(decision, id) do
    case logic_children(decision) do
      [] ->
        [error(id, "decision '#{id}' carries no decision logic")]

      [logic] ->
        name = Xml.local_name(logic)

        if name in @supported_logic do
          table_refusals(logic, name, id)
        else
          [
            error(
              id_of(logic) || id,
              "decision '#{id}' uses the boxed expression '#{name}'; the supported boxed " <>
                "expressions are decisionTable and literalExpression"
            )
          ]
        end

      many ->
        [
          error(
            id,
            "decision '#{id}' carries #{length(many)} boxed expressions " <>
              "(#{Enum.map_join(many, ", ", &Xml.local_name/1)}); a decision has exactly one"
          )
        ]
    end
  end

  defp table_refusals(logic, "decisionTable", decision_id) do
    table_id = id_of(logic) || decision_id
    policy = hit_policy(logic)
    aggregation = Xml.attr(logic, "aggregation")

    policy_errors =
      cond do
        policy in @refused_hit_policies ->
          [
            error(
              table_id,
              "hit policy #{spaced(policy)} is refused: it makes the order of the result list " <>
                "significant, so the decision's answer depends on where each rule sits in the " <>
                "document rather than on what the rules say. The implemented policies are " <>
                "UNIQUE, ANY, FIRST, PRIORITY and COLLECT with its aggregators"
            )
          ]

        policy not in @known_hit_policies ->
          [error(table_id, "'#{spaced(policy)}' is not a DMN hit policy")]

        true ->
          []
      end

    aggregation_errors =
      cond do
        is_nil(aggregation) ->
          []

        aggregation not in @known_aggregators ->
          [
            error(
              table_id,
              "'#{aggregation}' is not a DMN aggregator; the aggregators are " <>
                Enum.join(@known_aggregators, ", ")
            )
          ]

        policy != "COLLECT" ->
          [
            error(
              table_id,
              "aggregation '#{aggregation}' is set on a #{spaced(policy)} table; DMN gives " <>
                "aggregation a meaning only under COLLECT, so the engine would ignore it"
            )
          ]

        true ->
          []
      end

    policy_errors ++ aggregation_errors ++ table_expression_errors(logic, table_id)
  end

  defp table_refusals(logic, "literalExpression", decision_id) do
    expression_errors(literal_text(logic), id_of(logic) || decision_id, "the expression")
  end

  defp table_expression_errors(table, table_id) do
    input_errors =
      table
      |> Xml.children("input")
      |> Enum.flat_map(fn input ->
        id = id_of(input) || table_id

        input
        |> Xml.child("inputExpression")
        |> literal_text()
        |> expression_errors(id, "input clause '#{clause_label(input)}'")
      end)

    output_errors =
      table
      |> Xml.children("output")
      |> Enum.flat_map(fn output ->
        id = id_of(output) || table_id

        output
        |> Xml.child("defaultOutputEntry")
        |> literal_text()
        |> expression_errors(id, "the default output entry of '#{clause_label(output)}'")
      end)

    rule_errors =
      table
      |> Xml.children("rule")
      |> Enum.flat_map(&rule_expression_errors(&1, table_id))

    input_errors ++ output_errors ++ rule_errors
  end

  defp rule_expression_errors(rule, table_id) do
    id = id_of(rule) || table_id

    # Output entries are ordinary FEEL expressions and are parsed. Input entries
    # are unary tests -- a different grammar, which Boxic parses inside its
    # evaluator rather than exposing a parser for -- so all that can be checked
    # here is the size bound. See `AshDecisions.Feel.evaluate_unary_test/4`.
    outputs =
      rule
      |> Xml.children("outputEntry")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {entry, index} ->
        entry |> literal_text() |> expression_errors(id, "output entry #{index}")
      end)

    inputs =
      rule
      |> Xml.children("inputEntry")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {entry, index} ->
        text = literal_text(entry)

        case AshDecisions.Feel.check_size(text) do
          :ok -> []
          {:error, %{message: message}} -> [error(id, "input entry #{index}: #{message}")]
        end
      end)

    inputs ++ outputs
  end

  defp expression_errors(nil, _id, _what), do: []
  defp expression_errors("", _id, _what), do: []

  defp expression_errors(text, id, what) do
    case AshDecisions.Feel.parse(text) do
      {:ok, _ast} -> []
      {:error, %{message: message}} -> [error(id, "#{what} does not compile: #{message}")]
    end
  end

  # -- reference and cycle checking -----------------------------------------

  defp reference_errors(root) do
    decisions = decisions(root)
    decision_ids = MapSet.new(decisions, &id_of/1)
    input_ids = root |> Xml.descendants("inputData") |> MapSet.new(&id_of/1)

    unresolved =
      Enum.flat_map(decisions, fn decision ->
        id = id_of(decision)

        Enum.flat_map(requirements(decision), fn
          {:decision, href} ->
            unless_member(decision_ids, href, id, "no decision in this document has that id")

          {:input_data, href} ->
            unless_member(input_ids, href, id, "no inputData in this document has that id")
        end)
      end)

    unresolved ++ cycle_errors(decisions, decision_ids)
  end

  defp unless_member(set, href, id, why) do
    if MapSet.member?(set, href) do
      []
    else
      [
        error(
          id,
          "decision '#{id}' requires '#{href}', which does not resolve: #{why}. " <>
            "Imported requirements are not supported"
        )
      ]
    end
  end

  # A DRD whose decisions require each other in a loop has no evaluation order,
  # so it is refused at compile time rather than discovered as a stack overflow
  # the first time somebody asks it a question.
  defp cycle_errors(decisions, decision_ids) do
    edges =
      Map.new(decisions, fn decision ->
        deps =
          decision
          |> requirements()
          |> Enum.flat_map(fn
            {:decision, href} -> if MapSet.member?(decision_ids, href), do: [href], else: []
            {:input_data, _} -> []
          end)

        {id_of(decision), deps}
      end)

    edges
    |> Map.keys()
    |> Enum.flat_map(fn id ->
      if reaches?(edges, id, id, MapSet.new()) do
        [
          error(
            id,
            "decision '#{id}' is part of a requirement cycle, so it has no evaluation order"
          )
        ]
      else
        []
      end
    end)
  end

  defp reaches?(edges, from, target, seen) do
    edges
    |> Map.get(from, [])
    |> Enum.any?(fn next ->
      cond do
        next == target -> true
        MapSet.member?(seen, next) -> false
        true -> reaches?(edges, next, target, MapSet.put(seen, next))
      end
    end)
  end

  # -- the snapshot ----------------------------------------------------------

  defp build(root) do
    decisions = decisions(root)

    if decisions == [] do
      {:error, [error(id_of(root) || "definitions", "the document declares no decisions")]}
    else
      {:ok,
       %{
         "definitions_id" => id_of(root),
         "name" => Xml.attr(root, "name"),
         "namespace" => Xml.attr(root, "namespace"),
         "feel_engine" => %{
           "name" => "boxic_feel",
           "version" => version(:boxic_feel)
         },
         "dmn_engine" => %{
           "name" => "boxic_dmn",
           "version" => version(:boxic_dmn)
         },
         "input_data" =>
           root
           |> Xml.descendants("inputData")
           |> Map.new(fn el ->
             {id_of(el), %{"id" => id_of(el), "name" => Xml.attr(el, "name")}}
           end),
         "decision_order" => Enum.map(decisions, &id_of/1),
         "decisions" => Map.new(decisions, fn d -> {id_of(d), build_decision(d)} end)
       }}
    end
  end

  defp build_decision(decision) do
    {required_decisions, required_inputs} =
      decision
      |> requirements()
      |> Enum.split_with(fn {kind, _} -> kind == :decision end)

    base = %{
      "id" => id_of(decision),
      "name" => Xml.attr(decision, "name"),
      "requires" => %{
        "decisions" => Enum.map(required_decisions, &elem(&1, 1)),
        "input_data" => Enum.map(required_inputs, &elem(&1, 1))
      },
      "variable" => variable_name(decision)
    }

    [logic] = logic_children(decision)
    Map.merge(base, build_logic(logic, Xml.local_name(logic)))
  end

  defp build_logic(logic, "literalExpression") do
    %{"logic" => "literalExpression", "expression" => literal_text(logic)}
  end

  defp build_logic(table, "decisionTable") do
    %{
      "logic" => "decisionTable",
      "hit_policy" => hit_policy(table),
      "aggregation" => Xml.attr(table, "aggregation"),
      "output_label" => Xml.attr(table, "outputLabel"),
      "inputs" =>
        table
        |> Xml.children("input")
        |> Enum.map(fn input ->
          %{
            "id" => id_of(input),
            "label" => clause_label(input),
            "expression" => input |> Xml.child("inputExpression") |> literal_text(),
            "type_ref" => input |> Xml.child("inputExpression") |> attr_or_nil("typeRef")
          }
        end),
      "outputs" =>
        table
        |> Xml.children("output")
        |> Enum.map(fn output ->
          %{
            "id" => id_of(output),
            "label" => clause_label(output),
            "name" => Xml.attr(output, "name"),
            "type_ref" => Xml.attr(output, "typeRef"),
            "default_output_entry" => output |> Xml.child("defaultOutputEntry") |> literal_text()
          }
        end),
      "rules" =>
        table
        |> Xml.children("rule")
        |> Enum.map(fn rule ->
          %{
            "id" => id_of(rule),
            "description" => rule |> Xml.child("description") |> Xml.text() |> nil_if_empty(),
            "input_entries" => Enum.map(Xml.children(rule, "inputEntry"), &literal_text/1),
            "output_entries" => Enum.map(Xml.children(rule, "outputEntry"), &literal_text/1)
          }
        end)
    }
  end

  # -- small helpers ---------------------------------------------------------

  defp decisions(root), do: Xml.descendants(root, "decision")

  defp logic_children(decision) do
    decision |> Xml.children() |> Enum.filter(&(Xml.local_name(&1) in @boxed_expressions))
  end

  defp requirements(decision) do
    decision
    |> Xml.children("informationRequirement")
    |> Enum.flat_map(fn requirement ->
      cond do
        (ref = Xml.child(requirement, "requiredDecision")) != nil ->
          [{:decision, local_href(ref)}]

        (ref = Xml.child(requirement, "requiredInput")) != nil ->
          [{:input_data, local_href(ref)}]

        true ->
          []
      end
    end)
  end

  # An href is `#Decision_1` in the common case and `namespace#Decision_1` when
  # the document names its own namespace explicitly. Everything before the `#`
  # would be an import, and imports are refused above, so the local part is the
  # whole of what is left.
  defp local_href(ref) do
    case Xml.attr(ref, "href") do
      nil -> ""
      href -> href |> String.split("#") |> List.last()
    end
  end

  defp variable_name(decision) do
    case Xml.child(decision, "variable") do
      nil -> nil
      variable -> Xml.attr(variable, "name")
    end
  end

  # Normalized the way Boxic normalizes it, so a hit policy read off a snapshot
  # and a hit policy read off a loaded model are the same string.
  defp hit_policy(table) do
    case Xml.attr(table, "hitPolicy") do
      nil -> "UNIQUE"
      value -> value |> String.trim() |> String.upcase() |> String.replace(" ", "_")
    end
  end

  defp spaced(policy), do: String.replace(policy, "_", " ")

  defp clause_label(clause), do: Xml.attr(clause, "label") || Xml.attr(clause, "name")

  # Every FEEL-bearing element in DMN -- an inputExpression, an inputEntry, an
  # outputEntry, a literalExpression -- carries its source in a `<text>` child.
  defp literal_text(nil), do: nil

  defp literal_text(el) do
    case Xml.child(el, "text") do
      nil -> nil
      text -> text |> Xml.text() |> nil_if_empty()
    end
  end

  defp attr_or_nil(nil, _name), do: nil
  defp attr_or_nil(el, name), do: Xml.attr(el, name)

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(other), do: other

  defp id_of(el), do: Xml.attr(el, "id")

  defp version(app) do
    case Application.spec(app, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  defp render(term) when is_binary(term), do: term
  defp render(term), do: inspect(term, limit: 5, printable_limit: 200)

  defp error(path, message), do: %{path: path || "unknown", message: message}
end

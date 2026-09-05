defmodule AshDecisions.Catalogue do
  @moduledoc """
  A read-only projection of a domain's decisions, shaped for pickers and menus.

  A host — and `ash_bpmn`, which renders a business rule task as "pick a
  decision" — needs the same handful of answers about the same set of keys:
  which keys exist here, which of them have a draft in flight, which version is
  live right now, and what decisions the current document declares. A surface
  that answers those questions for itself will eventually disagree with one that
  answers them differently, so the projection lives here: over the same
  resources, reading the same snapshot the evaluator will run.

  `entries/2` is the whole API, and it reads only. It never compiles, never
  writes, and never touches the XML — the graph snapshot the compiler already
  wrote is its only view of the document, which is what keeps the DMN document
  the single artifact.
  """

  alias AshDecisions.Resources
  alias AshDecisions.Scope

  @typedoc "One input of one decision: the name it is called by, and a best-effort type."
  @type input :: %{name: String.t() | nil, type_ref: String.t() | nil}

  @typedoc "One output of one decision."
  @type output :: %{name: String.t() | nil, type_ref: String.t() | nil}

  @typedoc "One decision as the document declares it, in document order."
  @type decision :: %{name: String.t() | nil, inputs: [input()], outputs: [output()]}

  @typedoc "One definition key, as a picker would present it."
  @type entry :: %{
          key: String.t(),
          name: String.t(),
          status: :draft | :published,
          latest_published_version: pos_integer() | nil,
          has_draft: boolean(),
          decisions: [decision()]
        }

  @doc """
  Every definition key in `domain` that has a draft or a published version.

  One entry per key. Retired versions count for nothing on their own — a key
  whose every version is retired is history, not something to pick — and a
  retired version never counts as the latest published one.

  Entry fields:

    * `:key`, `:name` — the definition key, and the name of the definition you
      would open for it: the draft when one exists, else the latest published.
    * `:status` — `:draft` when the key has a draft, `:published` otherwise.
    * `:has_draft`, `:latest_published_version` — the two facts a picker shows
      next to the name. `latest_published_version` is `nil` for a key that has
      never been published.
    * `:decisions` — what the document declares, in document order, projected
      from the graph snapshot. The draft's snapshot when the draft has one;
      otherwise the latest published snapshot, because an author mid-edit has a
      draft that does not compile most of the time and the picker still wants to
      offer the decisions the key is about. A key with neither snapshot — an
      uncompiled draft that has never been published — offers `[]`.

  Options:

    * `:scope` — an `AshDecisions.Scope`, or a keyword of `:actor`/`:tenant`
      that one can be built from. The reads run under it, exactly the way the
      rest of this package's calls do.

  Raises if `domain` does not register both ash_decisions resources; a domain
  missing one is a host setup error, not a condition to report per call.
  """
  @spec entries(module(), keyword()) :: [entry()]
  def entries(domain, opts \\ []) do
    {:ok, %{definition: resource}} = Resources.for_domain(domain)

    read_opts = Scope.engine(scope_from(opts))

    resource
    |> Ash.Query.for_read(:read, %{}, read_opts)
    |> Ash.Query.do_filter(status: [in: [:draft, :published]])
    |> Ash.read!(read_opts)
    |> Enum.group_by(& &1.key)
    |> Enum.map(&entry/1)
    |> Enum.sort_by(& &1.key)
  end

  # ── one key ──────────────────────────────────────────────────────────────

  defp entry({key, versions}) do
    drafts = Enum.filter(versions, &(&1.status == :draft))
    published = Enum.filter(versions, &(&1.status == :published))

    # At most one draft per key is a database rule (the partial unique index),
    # so "the" draft needs no choosing; latest published does.
    draft = List.first(drafts)
    latest_published = Enum.max_by(published, & &1.version, fn -> nil end)

    %{
      key: key,
      name: (draft || latest_published).name,
      status: if(draft, do: :draft, else: :published),
      latest_published_version: latest_published && latest_published.version,
      has_draft: draft != nil,
      decisions:
        graph(draft, latest_published)
        |> decisions()
    }
  end

  # The draft's graph when the draft has one, else the latest published row's.
  # A published row always has a graph — publish refuses a draft with compile
  # errors, and a compiling draft always has one — but the attribute is read
  # defensively all the same: it is data, and the empty answer for data without
  # a snapshot is "no decisions", not a crash.
  defp graph(draft, latest_published) do
    case draft do
      %{graph: graph} when is_map(graph) -> graph
      _ -> latest_published && latest_published.graph
    end
  end

  # ── the document, as the compiler wrote it down ──────────────────────────

  # In `decision_order`, not map order: the compiler records the document's own
  # sequence because the order a business analyst drew is the order they expect
  # to see again.
  defp decisions(%{
         "decisions" => decisions,
         "input_data" => input_data,
         "decision_order" => order
       })
       when is_map(decisions) and is_list(order) do
    order
    |> Enum.map(&Map.get(decisions, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&decision(&1, input_data))
  end

  defp decisions(_), do: []

  defp decision(d, input_data) do
    %{
      name: d["name"],
      inputs: inputs(d, input_data),
      outputs: outputs(d)
    }
  end

  # The inputData a decision requires, by name. A requirement on another
  # decision is not an input — that is data flowing from a decision, and the
  # caller wires it by choosing both decisions, not by answering this one.
  defp inputs(d, input_data) do
    d
    |> Map.get("requires", %{})
    |> Map.get("input_data", [])
    |> List.wrap()
    |> Enum.map(fn id ->
      case input_data do
        %{^id => %{"name" => name}} ->
          %{name: name, type_ref: table_input_type_ref(d, name)}

        _ ->
          # Dangling references are refused at compile time, so this is not a
          # state a compiled snapshot can reach; a projection reads data, and
          # data can always be less than promised.
          %{name: nil, type_ref: nil}
      end
    end)
  end

  # Best effort by design. An input's type lives in the table clause whose
  # expression names it; a clause may express something else entirely (FEEL is
  # free text), and a non-table decision has no clauses at all. `nil` says "the
  # document does not answer", which is the truth.
  defp table_input_type_ref(d, input_name) do
    if d["logic"] == "decisionTable" and is_list(d["inputs"]) do
      Enum.find_value(d["inputs"], fn
        %{"expression" => ^input_name, "type_ref" => type_ref} -> type_ref
        _ -> nil
      end)
    else
      nil
    end
  end

  defp outputs(d) do
    case d do
      %{"logic" => "decisionTable", "outputs" => clause_outputs} when is_list(clause_outputs) ->
        Enum.map(clause_outputs, fn output ->
          # A table output is named, or in older documents merely labelled.
          %{name: output["name"] || output["label"], type_ref: output["type_ref"]}
        end)

      %{"logic" => "literalExpression"} ->
        # A literal expression answers in one value; the document names it in
        # the decision's variable, and types it nowhere.
        [%{name: d["variable"], type_ref: nil}]

      _ ->
        []
    end
  end

  # ── scope ────────────────────────────────────────────────────────────────

  defp scope_from(opts) do
    case Keyword.get(opts, :scope, %Scope{}) do
      %Scope{} = scope -> scope
      keyword when is_list(keyword) -> Scope.from_opts(keyword)
      _ -> %Scope{}
    end
  end
end

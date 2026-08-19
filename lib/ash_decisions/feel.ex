defmodule AshDecisions.Feel do
  @moduledoc """
  The FEEL seam: the only module in this package that calls `Boxic.FEEL`.

  Everything else — the compiler, the resources, anything a host writes on top —
  goes through `parse/2`, `evaluate/3`, `evaluate_unary_test/4` and `print/1`.
  That is a deliberate constraint rather than a tidiness preference. The engine
  is adopted, not written (see the README), and an adopted engine is a thing you
  may one day have to replace; keeping the calls in one module makes that a
  rewrite of one file instead of a sweep through every expression site in the
  package.

  ## Every expression here is hostile input

  Decision logic is authored by tenant administrators through a designer. A
  published rule is therefore a string that some customer's operations lead
  wrote, stored in your database, that this application will evaluate on demand
  inside its own web request. That is the same trust position as a user-supplied
  regular expression or a user-supplied template, and it gets the same three
  bounds.

  **A wall-clock timeout, enforced by killing a process.** `Task.async/1` plus
  `Task.shutdown(task, :brutal_kill)`, not a check the evaluator makes between
  steps. A pathological pattern handed to FEEL's `matches()` runs inside the
  regex engine and will not come back to be asked whether it would like to stop;
  the only thing that reliably ends it is the scheduler removing the process.
  `AshDecisions.Config.feel_timeout_ms/0`, default 250ms.

  **A size bound, before the tokenizer sees the string.** The cheapest way to
  make any parser expensive is to hand it a very long input.
  `AshDecisions.Config.feel_max_bytes/0`, default 4096 bytes.

  **A depth bound, after parsing.** Depth is a property of the tree, not of the
  text, so it can only be checked once there is a tree. Thirty-two is far past
  anything a person writes in a decision table cell and far short of anything
  that troubles the evaluator's stack. `AshDecisions.Config.feel_max_depth/0`.

  ## External functions are refused

  FEEL's `external` function definitions let a document name a Java class and a
  method. Boxic only makes external functions available when it is handed a
  registry through the `:external_functions` option, and this module never passes
  one — so a document that reaches for `java.lang.Math` gets an unresolved name
  rather than an invocation.

  Worth saying plainly: that refusal is *also* one of the entries in
  `AshDecisions.Tck.ExpectedFailures`. The `0076-feel-external-java` group does
  not pass, permanently and on purpose. The engine and the policy already agree,
  which is the arrangement you want — a safety rule that the conformance run
  contradicts is a safety rule someone will eventually turn off.

  ## The parse cache, and why it is shaped the way it is

  Evaluating a published decision means parsing the same handful of expression
  strings over and over, so `parse/2` memoises by SHA-256 of the source.

  The cache is `:persistent_term`, which is an unusual choice and a deliberate
  one. `:persistent_term` makes reads free and writes expensive — a write
  triggers a global scan. That is exactly backwards for a cache with churn and
  exactly right for this one: the set of distinct expressions in an application
  is fixed by the set of *published* definitions, so each entry is written once,
  ever, and then read for the lifetime of the node. There is no eviction for the
  same reason; evicting is a write, and a cache that evicts under load would turn
  a read-mostly structure into the churn it was chosen to avoid.

  What happens instead at the bound (`AshDecisions.Config.feel_cache_limit/0`) is
  that the cache stops growing and later expressions are parsed every time. Slow
  is the correct failure here — the alternative is unbounded memory driven by
  tenant-authored content.

  ## What is not stored

  Not the AST. `Boxic`'s AST is tagged tuples containing `Decimal` structs:
  expressive, not JSON, and carrying no version tag of its own. A compiled
  expression lives inside a `Definition.graph` snapshot that has to survive an
  upgrade of the engine underneath an in-flight caller, and a tuple tree that
  changes shape between releases cannot do that. So the snapshot stores the FEEL
  **source text** and the engine version that validated it, and evaluation parses
  through this cache. See `AshDecisions.Compiler`.
  """

  @typedoc "Boxic's parsed representation. Opaque here on purpose — see the moduledoc."
  @type ast :: term()

  @typedoc """
  A FEEL failure, flattened.

  Callers get `%{code: atom, message: binary}` whether the failure came from the
  tokenizer, the evaluator, one of this module's own bounds, or the timeout —
  which is the point of the seam. `Boxic.FEEL.Error` does not escape this module.
  """
  @type error :: %{code: atom(), message: String.t()}

  @cache_count_key {__MODULE__, :cache_count}

  @doc """
  Parses FEEL source into the engine's representation.

  Applies the size bound before parsing and the depth bound after it. Successful
  parses are memoised; pass `cache: false` to skip both reading and writing the
  cache.

  ## Options

    * `:cache` — default `true`.
    * `:max_bytes`, `:max_depth`, `:timeout` — override the configured bounds.
  """
  @spec parse(String.t(), keyword()) :: {:ok, ast()} | {:error, error()}
  def parse(source, opts \\ []) when is_binary(source) do
    cache? = Keyword.get(opts, :cache, true)
    key = cache_key(source)

    case cache? && cache_get(key) do
      {:ok, ast} ->
        {:ok, ast}

      _ ->
        with :ok <- check_size(source, opts),
             {:ok, ast} <- do_parse(source, opts),
             :ok <- check_depth(ast, opts) do
          if cache?, do: cache_put(key, ast)
          {:ok, ast}
        end
    end
  end

  @doc """
  Evaluates FEEL source against a context, under the timeout.

  The context is a plain map with **string** keys, which is Boxic's convention
  and also the shape a decision's inputs arrive in from JSON.
  """
  @spec evaluate(String.t(), map(), keyword()) :: {:ok, term()} | {:error, error()}
  def evaluate(source, context, opts \\ []) when is_binary(source) and is_map(context) do
    with {:ok, ast} <- parse(source, opts) do
      bounded(opts, fn -> Boxic.FEEL.evaluate_ast(ast, context) end)
    end
  end

  @doc """
  Evaluates a FEEL **unary test** — a decision table input entry — against a value.

  Unary tests are their own grammar (`< 10`, `"a", "b"`, `[1..5]`, `-`) and Boxic
  parses them inside its evaluator rather than exposing a parser for them. They
  therefore do not go through the parse cache, and the size bound is applied here
  directly. `AshDecisions.Compiler` says the same thing from the other side: it
  can prove a rule's *output* entries parse at publish time, and it cannot prove
  that of the input entries.

  One cell is a comma-separated **disjunction** of tests, so `"gold", "silver"`
  matches either. Boxic's `evaluate_unary_test/3` is the single-test primitive
  and does not split; the splitting lives in `boxic_dmn`'s decision table. It is
  reimplemented here — carefully, on top-level commas only, so a comma inside a
  string literal is left alone — because a seam that answered a decision table
  cell differently from the way the engine answers it would be worse than no seam
  at all.
  """
  @spec evaluate_unary_test(String.t(), term(), map(), keyword()) ::
          {:ok, boolean()} | {:error, error()}
  def evaluate_unary_test(test, value, context \\ %{}, opts \\ [])
      when is_binary(test) and is_map(context) do
    with :ok <- check_size(test, opts) do
      # The split runs inside the timeout too: it is a regex over a
      # tenant-authored string, which is exactly the thing this module refuses to
      # run unbounded anywhere else.
      bounded(opts, fn ->
        test
        |> split_unary_tests()
        |> Enum.reduce_while({:ok, false}, fn one, {:ok, false} ->
          case Boxic.FEEL.evaluate_unary_test(one, value, context) do
            {:ok, true} -> {:halt, {:ok, true}}
            {:ok, false} -> {:cont, {:ok, false}}
            {:error, _} = error -> {:halt, error}
          end
        end)
      end)
    end
  end

  # A comma at the top level separates tests; a comma inside a string literal
  # does not. An empty cell is the same thing as `-`: it matches anything.
  defp split_unary_tests(text) do
    case String.trim(text) do
      "" ->
        ["-"]

      trimmed ->
        ~r/,(?=(?:[^"]*"[^"]*")*[^"]*$)/
        |> Regex.split(trimmed, trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  @doc """
  Converts an Elixir value into one the engine can navigate and compare.

  Three rules, and the first is the one that silently ruins a decision table if it is missed:

    * **Integers and floats become `Decimal`.** FEEL's numeric model is decimal, and a literal
      in an input entry parses to a `Decimal`. An Elixir integer left in the context makes
      `< 1000` a type error, which FEEL folds to `null`, which a decision table reads as
      "this rule did not match". No rule matches, the table returns null, and nothing anywhere
      reports a problem. This conversion is the difference between a working table and a
      silently empty one.
    * **Keys become strings**, because that is what a FEEL context is.
    * **Unloaded and forbidden fields are dropped, not nilled.** A dropped key is a missing
      path is `null` -- the honest answer for a value we do not have, and the only safe one
      for a field the actor may not read: nilling it would let a hidden value decide a case.

  The same function exists in `AshBpmn.Feel`, because both packages adapt the same engine and
  neither may depend on the other. The duplication is the price of the seam, and it is a
  smaller price than a shared package that both would then have to version against.
  """
  @spec to_feel_value(term(), non_neg_integer()) :: term()
  def to_feel_value(value, depth \\ 3)

  def to_feel_value(_value, depth) when depth < 0, do: nil
  def to_feel_value(nil, _depth), do: nil

  def to_feel_value(%Ash.NotLoaded{}, _depth), do: :__drop__
  def to_feel_value(%Ash.ForbiddenField{}, _depth), do: :__drop__

  # See the moduledoc for this function: the single most consequential line in the adapter.
  def to_feel_value(value, _depth) when is_integer(value), do: Decimal.new(value)
  def to_feel_value(value, _depth) when is_float(value), do: Decimal.from_float(value)

  # Values the engine models itself are passed through untouched.
  def to_feel_value(%Decimal{} = value, _depth), do: value
  def to_feel_value(%Date{} = value, _depth), do: value
  def to_feel_value(%Time{} = value, _depth), do: value
  def to_feel_value(%DateTime{} = value, _depth), do: value
  def to_feel_value(%NaiveDateTime{} = value, _depth), do: value
  def to_feel_value(%Boxic.FEEL.Time{} = value, _depth), do: value
  def to_feel_value(%Boxic.FEEL.DateTime{} = value, _depth), do: value
  def to_feel_value(%Boxic.FEEL.Duration{} = value, _depth), do: value
  def to_feel_value(%Boxic.FEEL.Range{} = value, _depth), do: value

  def to_feel_value(%_struct{} = record, depth) do
    record
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :__order__, :__lateral_join_source__])
    |> to_feel_value(depth)
  end

  def to_feel_value(map, depth) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      case to_feel_value(value, depth - 1) do
        :__drop__ -> acc
        converted -> Map.put(acc, to_string(key), converted)
      end
    end)
  end

  def to_feel_value(list, depth) when is_list(list) do
    list
    |> Enum.map(&to_feel_value(&1, depth - 1))
    |> Enum.reject(&(&1 == :__drop__))
  end

  def to_feel_value(value, _depth) when is_atom(value) and not is_boolean(value),
    do: to_string(value)

  def to_feel_value(value, _depth), do: value

  @doc """
  Renders an engine value as the FEEL source text that would produce it.

  The other half of the seam. Engine values are engine-shaped — `Decimal`,
  `Boxic.FEEL.Duration`, `Boxic.FEEL.Time` — and anything in this package that
  formatted them itself would be a second module that knows the representation,
  which is the thing this module exists to prevent.

  Round-tripping is the intent rather than a guarantee: `print/1` on a value
  produced by `evaluate/3` yields source that a person can read and that
  `evaluate/3` will accept, but a closure has no source text and renders as
  `function(…)`.
  """
  @spec print(term()) :: String.t()
  def print(nil), do: "null"
  def print(true), do: "true"
  def print(false), do: "false"
  def print(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  def print(n) when is_integer(n), do: Integer.to_string(n)
  def print(n) when is_float(n), do: Float.to_string(n)
  def print(s) when is_binary(s), do: "\"" <> escape(s) <> "\""
  def print(%Date{} = d), do: ~s|date("#{Date.to_iso8601(d)}")|
  def print(%Boxic.FEEL.Time{} = t), do: ~s|time("#{Boxic.FEEL.Time.to_string(t)}")|

  def print(%Boxic.FEEL.DateTime{} = dt),
    do: ~s|date and time("#{Boxic.FEEL.DateTime.to_string(dt)}")|

  def print(%Boxic.FEEL.Duration{} = d), do: ~s|duration("#{Boxic.FEEL.Duration.to_string(d)}")|

  def print(%Boxic.FEEL.Range{} = r) do
    open = if r.start_inclusive, do: "[", else: "("
    close = if r.end_inclusive, do: "]", else: ")"
    open <> print(r.start) <> ".." <> print(r.end) <> close
  end

  def print(%Boxic.FEEL.Function{params: params}) do
    "function(" <> Enum.map_join(params, ", ", fn {name, _type} -> name end) <> ")"
  end

  def print(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &print/1) <> "]"

  def print(map) when is_map(map) do
    "{" <>
      (map
       |> Enum.sort_by(fn {k, _} -> to_string(k) end)
       |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{print(v)}" end)) <> "}"
  end

  def print(other), do: inspect(other)

  @doc """
  Empties the parse cache.

  For tests, and for a host that has just retired every definition it had. Not
  something a running application should need — see the moduledoc on why the
  cache does not evict.
  """
  @spec flush_cache() :: :ok
  def flush_cache do
    for {{__MODULE__, :ast, _} = key, _} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :persistent_term.erase(@cache_count_key)
    :ok
  end

  # -- bounds ---------------------------------------------------------------

  @doc """
  Checks a string against the size bound without parsing it.

  Public because `AshDecisions.Compiler` needs it for decision table input
  entries: those are unary tests, which Boxic parses inside its evaluator rather
  than exposing a parser for, so the size bound is the only one of the three that
  can be applied to them ahead of time.
  """
  @spec check_size(String.t(), keyword()) :: :ok | {:error, error()}
  def check_size(source, opts \\ [])

  def check_size(nil, _opts), do: :ok

  def check_size(source, opts) when is_binary(source) do
    max = Keyword.get(opts, :max_bytes) || AshDecisions.Config.feel_max_bytes()

    if byte_size(source) > max do
      {:error,
       err(
         :expression_too_large,
         "expression is #{byte_size(source)} bytes; the limit is #{max}"
       )}
    else
      :ok
    end
  end

  defp check_depth(ast, opts) do
    max = Keyword.get(opts, :max_depth) || AshDecisions.Config.feel_max_depth()
    actual = depth(ast)

    if actual > max do
      {:error, err(:expression_too_deep, "expression nests #{actual} deep; the limit is #{max}")}
    else
      :ok
    end
  end

  # Structs are leaves. A `Decimal` is a value the parser produced, not nesting
  # the author wrote, and counting its fields would make `1 + 2` look deep.
  defp depth(%_{}), do: 0
  defp depth(t) when is_tuple(t), do: t |> Tuple.to_list() |> deepest()
  defp depth(l) when is_list(l), do: deepest(l)
  defp depth(m) when is_map(m), do: m |> Map.values() |> deepest()
  defp depth(_), do: 0

  defp deepest(items) do
    1 + Enum.reduce(items, 0, fn item, acc -> max(acc, depth(item)) end)
  end

  # -- the timeout ----------------------------------------------------------

  # `Task.async/1` links, so a task that exits abnormally would take the caller
  # with it. Everything the task can raise or throw is therefore turned into a
  # value inside the task, and the only abnormal exit left is the brutal kill
  # this function performs itself.
  defp bounded(opts, fun) do
    timeout = Keyword.get(opts, :timeout) || AshDecisions.Config.feel_timeout_ms()

    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          e -> {:error, err(:evaluation_raised, Exception.message(e))}
        catch
          kind, reason ->
            {:error, err(:evaluation_threw, "#{kind}: #{inspect(reason, limit: 5)}")}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, value}} ->
        {:ok, value}

      {:ok, {:error, %Boxic.FEEL.Error{} = e}} ->
        {:error, err(e.code, e.message)}

      {:ok, {:error, %{code: _, message: _} = e}} ->
        {:error, e}

      {:ok, {:error, other}} ->
        {:error, err(:evaluation_failed, inspect(other, limit: 5))}

      {:exit, reason} ->
        {:error, err(:evaluation_exited, inspect(reason, limit: 5))}

      nil ->
        {:error, err(:timeout, "expression did not finish within #{timeout}ms")}
    end
  end

  defp do_parse(source, opts) do
    bounded(opts, fn -> Boxic.FEEL.parse(source) end)
  end

  # -- the cache ------------------------------------------------------------

  defp cache_key(source), do: {__MODULE__, :ast, :crypto.hash(:sha256, source)}

  defp cache_get(key) do
    case :persistent_term.get(key, :miss) do
      :miss -> :miss
      ast -> {:ok, ast}
    end
  end

  defp cache_put(key, ast) do
    count = :persistent_term.get(@cache_count_key, 0)

    if count < AshDecisions.Config.feel_cache_limit() do
      :persistent_term.put(key, ast)
      :persistent_term.put(@cache_count_key, count + 1)
    end

    :ok
  end

  # -- misc -----------------------------------------------------------------

  defp err(code, message), do: %{code: code, message: message}

  defp escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end

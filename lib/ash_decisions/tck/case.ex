defmodule AshDecisions.Tck.Case do
  @moduledoc """
  One `testCase` from a TCK expectation file, parsed into something runnable.

  A case names a model, supplies zero or more input nodes, and asserts one or more result
  nodes.

  ## `errorResult="true"` does not mean "raise"

  Roughly 40% of the corpus marks a result node `errorResult="true"`, and it is tempting to
  read that as "the engine must fail". It does not. FEEL has no exceptions: an erroneous
  expression evaluates to `null`, and the corpus says so itself — those nodes almost always
  carry an explicit `<expected><value xsi:nil="true"/></expected>` alongside the flag.

  So the flag is recorded, and the expectation is still read. A result satisfies it if the
  engine returned `null` **or** reported an error. Requiring an error instead marks a
  correctly-implemented engine wrong on nearly every division-by-zero and type-mismatch case
  in the corpus.
  """

  alias AshDecisions.Tck.{Value, Xml}

  defstruct [
    :group,
    :level,
    :model_path,
    :case_file,
    :id,
    :description,
    :type,
    :invocable,
    :inputs,
    :results
  ]

  @type result :: %{name: String.t(), expects_error?: boolean(), expected: term()}
  @type t :: %__MODULE__{
          group: String.t(),
          level: String.t(),
          model_path: Path.t(),
          case_file: Path.t(),
          id: String.t(),
          description: String.t() | nil,
          type: String.t(),
          invocable: String.t() | nil,
          inputs: %{String.t() => term()},
          results: [result()]
        }

  @doc "Parses every `testCase` in one expectation file."
  @spec load_file(Path.t(), String.t(), String.t()) :: {:ok, [t()]} | {:error, String.t()}
  def load_file(case_file, group, level) do
    with {:ok, xml} <- File.read(case_file),
         {:ok, root} <- Xml.parse(xml) do
      model_name = root |> Xml.child("modelName") |> Xml.text()
      model_path = Path.join(Path.dirname(case_file), model_name)

      root
      |> Xml.children("testCase")
      |> Enum.reduce_while({:ok, []}, fn el, {:ok, acc} ->
        case parse_case(el, group, level, model_path, case_file) do
          {:ok, c} -> {:cont, {:ok, [c | acc]}}
          {:error, reason} -> {:halt, {:error, "#{case_file}: #{reason}"}}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end
    end
  end

  defp parse_case(el, group, level, model_path, case_file) do
    with {:ok, inputs} <- parse_inputs(el),
         {:ok, results} <- parse_results(el) do
      {:ok,
       %__MODULE__{
         group: group,
         level: level,
         model_path: model_path,
         case_file: case_file,
         id: Xml.attr(el, "id"),
         description: el |> Xml.child("description") |> Xml.text() |> nil_if_blank(),
         # An absent `type` means `decision`; the corpus writes it both ways.
         type: Xml.attr(el, "type") || "decision",
         invocable: Xml.attr(el, "invocableName"),
         inputs: inputs,
         results: results
       }}
    end
  end

  defp parse_inputs(el) do
    el
    |> Xml.children("inputNode")
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, acc} ->
      case Value.read(node) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, Xml.attr(node, "name"), value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_results(el) do
    el
    |> Xml.children("resultNode")
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      expects_error? = Xml.attr(node, "errorResult") in ["true", "1"]

      expected =
        case Xml.child(node, "expected") do
          nil -> {:ok, nil}
          expected -> Value.read(expected)
        end

      case expected do
        {:ok, value} ->
          {:cont,
           {:ok,
            [
              %{name: Xml.attr(node, "name"), expects_error?: expects_error?, expected: value}
              | acc
            ]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(other), do: other
end

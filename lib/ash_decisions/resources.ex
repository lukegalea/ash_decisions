defmodule AshDecisions.Resources do
  @moduledoc """
  Resource macro registry and introspection helpers.

  Each `use AshDecisions.Resources.X` macro generates a function
  `ash_decisions_kind/0` on the host module. This module provides `kind/1` to
  sniff any loaded module and `for_domain/1` to locate both resources inside a
  domain.

  Sniffing rather than configuration is deliberate, and it is the same choice
  `ash_bpmn` made. A host names its own modules and puts them in its own domain;
  asking it to *also* list them in application config gives two sources of truth
  that drift apart silently, and the drift only shows up as a decision evaluated
  against the wrong table.
  """

  @kinds [:definition, :evaluation]

  @doc "Returns the `@ash_decisions_kind` atom for a loaded module, or `:not_ash_decisions`."
  @spec kind(module()) :: atom()
  def kind(module) do
    module.ash_decisions_kind()
  rescue
    ArgumentError -> :not_ash_decisions
    UndefinedFunctionError -> :not_ash_decisions
  end

  @doc """
  Locates both ash_decisions resource modules registered in the given domain.

  Returns `{:ok, map}` where each key is a kind atom and each value is the
  resource module, or `{:error, :missing_resources, [kinds]}` if any are absent.
  """
  @spec for_domain(module()) :: {:ok, map()} | {:error, :missing_resources, [atom()]}
  def for_domain(domain) do
    resources = Ash.Domain.Info.resources(domain)

    mapping =
      for kind <- @kinds, into: %{} do
        mod = Enum.find(resources, fn r -> kind(r) == kind end)
        {kind, mod}
      end

    missing = Enum.reject(@kinds, fn k -> mapping[k] end)

    case missing do
      [] -> {:ok, mapping}
      _ -> {:error, :missing_resources, missing}
    end
  end
end

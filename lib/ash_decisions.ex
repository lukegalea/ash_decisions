defmodule AshDecisions do
  @moduledoc """
  DMN decisions as versioned, tenant-scoped, auditable Ash resources.

  See `README.md` for what exists today. The public facade — `evaluate/3`, `publish/2` and
  the resource macros — is being built on top of the conformance harness in
  `AshDecisions.Tck`, which settled the question of which engine to build on.
  """
end

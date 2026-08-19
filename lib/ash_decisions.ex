defmodule AshDecisions do
  @moduledoc """
  DMN decisions as versioned, tenant-scoped, auditable Ash resources.

  Two resource macros, a compiler and a FEEL seam:

    * `AshDecisions.Resources.Definition` — the DMN document, versioned, with a
      `draft → published → retired` lifecycle.
    * `AshDecisions.Resources.Evaluation` — append-only evidence of what each
      invoked decision saw and decided.
    * `AshDecisions.Compiler` — DMN in, immutable snapshot out, refusing by
      element id the constructs it does not execute.
    * `AshDecisions.Feel` — the only module that touches the engine, and the
      place the bounds on tenant-authored expressions are enforced.

  `AshDecisions.Scope` carries the actor and the tenant through everything above;
  `AshDecisions.Checks.AshDecisionsInteraction` is what makes that package's own
  writes a declared part of a resource's policy set rather than an option at a
  call site.

  There is no `evaluate/3` facade yet. See `README.md` for what exists and what
  does not; the conformance harness in `AshDecisions.Tck` is what settled which
  engine all of this sits on.
  """
end

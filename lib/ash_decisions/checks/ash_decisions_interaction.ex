defmodule AshDecisions.Checks.AshDecisionsInteraction do
  @moduledoc """
  Passes when ash_decisions itself is the caller.

  This package has to write rows a person has no action for. Creating a
  definition assigns its version by reading the versions that already exist;
  recording an evaluation writes an append-only row on a resource nobody is
  given a create action to call directly. None of that is a user operation, and
  no host policy should have to enumerate it.

  The obvious way to express that is `authorize?: false` on the package's own
  calls. The trouble with that is not that any one of them is wrong. It is that
  `authorize?: false` is indistinguishable from a mistake at a glance, it is
  invisible to a host's policies, and adding the next one is a one-line diff that
  nothing reviews.

  So the package marks its own calls instead:

      Ash.read_one!(query, AshDecisions.Scope.engine(scope))

  which sets `context: %{private: %{ash_decisions?: true}}`, and every generated
  resource carries one policy that recognises it:

      policies do
        bypass AshDecisions.Checks.AshDecisionsInteraction do
          authorize_if always()
        end
      end

  The bypass is one named, greppable, testable thing rather than a scattering of
  anonymous ones, and a host reading the resource's policies can *see* the
  library's path through them.

  ## What this is not

  It is not a security boundary against the host application. Anything that can
  set private context could equally have passed `authorize?: false`, so this does
  not make the package harder to impersonate from inside the same BEAM. What it
  changes is that the authority is now declared in the policy set, where it can
  be read, reasoned about and — if a host disagrees — replaced.

  The bypass can be dropped entirely with `policies?: false` on the resource
  macro, in which case the host owns the whole policy set and must grant this
  package whatever it needs. With an authorizer and nothing to satisfy it, such a
  resource refuses everyone; that is the correct consequence of the option rather
  than an oversight.

  ## Ordering matters, in one direction

  Ash does not walk policies one at a time; it folds them into a single boolean
  expression and solves it. The fold is still order-sensitive, and in exactly the
  way the DSL documentation implies: a bypass contributes a disjunct covering the
  policies **after** it, so a bypass authorizes a request only when the
  restrictive policies it needs to skip were declared later.

  For a resource whose whole policy set comes from the macro that is automatic —
  the bypass is the only policy there is. It matters as soon as a host is
  involved:

    * A host adding `policies do … end` **after** `use AshDecisions.Resources.X`:
      fine, the bypass is already ahead of it.
    * A host using `:base` where the base ships its own policy set: **not** fine.
      `use <base>` expands first, so the base's policies precede this bypass and
      the package is forbidden. `AshDecisions.Config.engine_actor/0` documents the
      two ways out, and `base_resource_test.exs` pins both behaviours so neither
      can change quietly.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the ash_decisions library is the caller"

  @impl true
  def match?(_actor, %{subject: %{context: %{private: %{ash_decisions?: true}}}}, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end

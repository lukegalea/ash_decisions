defmodule AshDecisions.Config do
  @moduledoc """
  Runtime configuration for the ash_decisions library.

  Reads from `Application.get_env(:ash_decisions, ...)`. Everything here has a
  documented default; this package has no setting a host is obliged to supply.

  The FEEL limits are the interesting half. Decision logic is authored by tenant
  administrators through a designer, which makes every expression in a published
  definition untrusted input that this application will happily run — so the
  limits are not tuning knobs, they are the boundary. `AshDecisions.Feel`
  enforces all three and explains what each one stops.
  """

  @doc """
  Returns the actor the evaluator acts as, or `nil` to keep the caller's own.

  By default the caller's actor survives: the person whose request caused a
  decision to be evaluated is the person the evaluation record is attributed to,
  and the package's authority to write that record travels separately, in the
  private context flag `AshDecisions.Checks.AshDecisionsInteraction` recognises.
  That is what lets a host base resource derive ownership, provenance and its
  audit entry from a human rather than from a library.

  It stops working in one case, and it is worth stating precisely. Ash folds a
  resource's policies into one expression in which a bypass short-circuits only
  the policies declared **after** it. A host base resource emits its policy set
  from `use`, which runs before anything the ash_decisions resource macro adds —
  so on a based resource the host's policies come first and the bypass never gets
  the chance to skip them.

  A host in that position has two ways out. Either put the bypass at the top of
  the base's own policy set:

      policies do
        bypass AshDecisions.Checks.AshDecisionsInteraction do
          authorize_if always()
        end

        # … the rest of the base's policies
      end

  or, if changing the base is not an option, tell this package to act as an actor
  the base already admits:

      config :ash_decisions,
        engine_actor: {MyApp.Platform.SystemActor, :system, []}

  The MFA is evaluated per call. The cost of the second option is why it is not
  the default: every write this package makes is then attributed to that system
  actor, and the human survives only in columns written explicitly.
  """
  @spec engine_actor() :: term() | nil
  def engine_actor do
    case Application.get_env(:ash_decisions, :engine_actor) do
      nil -> nil
      {m, f, a} -> apply(m, f, a)
      actor -> actor
    end
  end

  @doc """
  Milliseconds a single FEEL evaluation may run for (default `250`).

  A decision that has not answered in a quarter of a second has not answered.
  See `AshDecisions.Feel` for why this is enforced by killing a process rather
  than by asking the evaluator to check the clock.
  """
  @spec feel_timeout_ms() :: pos_integer()
  def feel_timeout_ms do
    Application.get_env(:ash_decisions, :feel_timeout_ms, 250)
  end

  @doc """
  Maximum size in bytes of a single FEEL expression (default `4096`).

  Checked before the tokenizer sees the string, because the cheapest way to make
  a parser expensive is to hand it a very long input.
  """
  @spec feel_max_bytes() :: pos_integer()
  def feel_max_bytes do
    Application.get_env(:ash_decisions, :feel_max_bytes, 4096)
  end

  @doc """
  Maximum nesting depth of a parsed FEEL expression (default `32`).

  Checked after parsing, because depth is a property of the tree rather than of
  the text. Thirty-two is far past anything a person writes in a decision table
  cell and far short of anything that troubles the evaluator's stack.
  """
  @spec feel_max_depth() :: pos_integer()
  def feel_max_depth do
    Application.get_env(:ash_decisions, :feel_max_depth, 32)
  end

  @doc """
  Maximum number of distinct expressions the parse cache will hold (default `4096`).

  Reaching the bound stops the cache growing rather than evicting from it; see
  `AshDecisions.Feel` for why an unbounded cache and an evicting cache are both
  the wrong shape for what is being cached.
  """
  @spec feel_cache_limit() :: pos_integer()
  def feel_cache_limit do
    Application.get_env(:ash_decisions, :feel_cache_limit, 4096)
  end
end

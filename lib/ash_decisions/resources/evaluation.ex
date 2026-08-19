defmodule AshDecisions.Resources.Evaluation do
  @moduledoc """
  Resource macro for the record of a decision having been made.

  One row per **invoked decision**, not per request. A DRD with three decisions
  joined by `informationRequirement` edges produces three rows when it is asked
  for its final answer, because "which rule decided this, and what did it see"
  is a question about each decision individually — an auditor asking why a claim
  was declined needs the eligibility decision's inputs, not only the outcome the
  decision that depended on it produced. `correlation_id` is what ties them back
  together into one request.

  The rows are **append-only**: `create` and `read`, no update, no destroy. Not a
  convention — the macro simply generates no other actions, so there is nothing
  to call. A record of what a rule decided that can be edited afterwards is not
  evidence of anything.

  ## Options

    * `:domain` — **required**. The Ash domain this resource belongs to.
    * `:repo` — **required**. The `AshPostgres.Repo` for this resource.
    * `:definition` — the Definition resource module. Optional: supply it to get
      a `belongs_to :definition` relationship for loading. Without it the row
      still carries `definition_id`, and that is the whole of what it needs — the
      key and version are denormalised onto the row precisely so the evidence
      survives whatever later happens to the definition.
    * `:table` — table name (default `"dmn_evaluations"`).
    * `:tenant?` — set `true` to add `organization_id` multitenancy (default `false`).
    * `:base` — the module to `use` in place of `Ash.Resource`. See
      `AshDecisions.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled in.
    * `:policies?` — emit the library bypass policy (default `true`). See
      `AshDecisions.Checks.AshDecisionsInteraction`.

  ## Why the key and version are on the row

  `definition_id` is enough to find the definition today. `definition_key` and
  `definition_version` are enough to *read the row* in five years, when the
  definition has been retired, when a host's soft delete has hidden it, or when
  a restore has renumbered nothing but moved everything. An evidence row that
  can only be understood by joining to a mutable table is evidence with a
  dependency, and the dependency is the part that fails.

  ## An error is an outcome

  `error` is nullable and holds the failure when a decision did not produce one:
  a FEEL expression that raised, a `UNIQUE` table that matched twice, an
  evaluation that hit the timeout in `AshDecisions.Feel`. Those rows are written,
  not swallowed. "The rule engine was asked and could not answer" is one of the
  more important things an audit trail can say, and it is invisible in a design
  where only successes are recorded.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    definition = Keyword.get(opts, :definition)
    table = Keyword.get(opts, :table, "dmn_evaluations")
    tenant? = AshDecisions.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshDecisions.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_decisions_kind :evaluation

      def ash_decisions_kind, do: @ash_decisions_kind

      postgres do
        table(unquote(table))
        repo(unquote(repo))

        custom_indexes do
          # The two ways this table is read: everything one definition ever
          # decided, and everything one request decided. Both are answered
          # against a log that only ever grows, which is exactly the shape that
          # goes badly without an index.
          index([:definition_id])
          index([:correlation_id])
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy(:attribute)
          attribute(:organization_id)
          global?(true)
        end
      end

      if unquote(policies?) do
        policies do
          bypass AshDecisions.Checks.AshDecisionsInteraction do
            authorize_if(always())
          end
        end
      end

      attributes do
        uuid_primary_key(:id)

        attribute :definition_id, :uuid do
          allow_nil?(false)
          public?(true)
        end

        # Denormalised on purpose -- see the moduledoc.
        attribute :definition_key, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :definition_version, :integer do
          allow_nil?(false)
          public?(true)
        end

        # The DMN id of the decision that was invoked, not of the document.
        attribute :decision_id, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :inputs, :map do
          default(%{})
          public?(true)
        end

        attribute :outputs, :map do
          default(%{})
          public?(true)
        end

        # Which rules fired. For a UNIQUE or FIRST table this is one id; for
        # COLLECT it is however many matched. It is the difference between "the
        # answer was 12%" and "the answer was 12% because rule 7 matched".
        attribute :matched_rule_ids, {:array, :string} do
          default([])
          public?(true)
        end

        attribute :hit_policy, :string do
          public?(true)
        end

        attribute :duration_us, :integer do
          public?(true)
        end

        attribute :error, :map do
          public?(true)
        end

        attribute :correlation_id, :string do
          public?(true)
        end

        if unquote(tenant?) do
          attribute :organization_id, :uuid do
            allow_nil?(false)
            public?(true)
            writable?(false)
          end
        end

        timestamps()
      end

      if unquote(definition) do
        relationships do
          belongs_to :definition, unquote(definition) do
            define_attribute?(false)
            allow_nil?(false)
            public?(true)
          end
        end
      end

      # Create and read. There is deliberately no update and no destroy: see the
      # moduledoc on why a record of what a rule decided must not be editable.
      actions do
        read :read do
          primary?(true)
        end

        create :create do
          accept([
            :definition_id,
            :definition_key,
            :definition_version,
            :decision_id,
            :inputs,
            :outputs,
            :matched_rule_ids,
            :hit_policy,
            :duration_us,
            :error,
            :correlation_id
          ])
        end
      end

      code_interface do
        define(:create, action: :create)
        define(:read, action: :read)
      end
    end
  end
end

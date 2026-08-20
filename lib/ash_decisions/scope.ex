defmodule AshDecisions.Scope do
  @moduledoc """
  Who is acting, and in which tenant — carried through every call this package
  makes into Ash.

  A decision resource is versioned, tenant-scoped and append-only, which means
  every write this package makes has two questions attached to it that a library
  is very good at losing: *whose* decision was this, and *whose data* was it
  decided against. A scope is the smallest thing that carries both. It is
  resolved once, at the boundary of a public function, and threaded down.

      scope = AshDecisions.Scope.from_opts(opts)
      Ash.read_one!(query, AshDecisions.Scope.engine(scope))

  This is `AshBpmn.Scope` with the names changed, deliberately: the two packages
  are halves of one platform, a business rule task in a process hands off to a
  decision, and a scope that meant something different on either side of that
  handoff would be a bug looking for somewhere to happen.

  ## Where a scope comes from

    * `from_opts/1` — a caller's `:actor` and `:tenant`, at a facade entry point.
    * `from_record/2` — a record already in hand. The tenant is read off the
      record's `organization_id`, which is the point of attribute multitenancy:
      the row knows which tenant it is in, so an operation on it does not need to
      be told again.
    * `from_changeset/1` — for the reads a change or validation makes against its
      own resource, so that "what is the highest version of this key" is asked
      inside the tenant the changeset is being written into and nowhere else.
    * `from_job/2` — a job's args, where the tenant travelled as JSON.

  ## Why the actor stays the human

  `engine/2` sets a private context flag rather than substituting a system actor,
  so the real person stays in `actor:` for the whole call. That matters under a
  host base resource, where ownership, provenance and the audit entry are all
  derived from the actor: an evaluation has to be attributable to whoever asked
  for the decision, not to the library that carried the write. This package's
  authority to make the write travels separately, in the context flag that
  `AshDecisions.Checks.AshDecisionsInteraction` recognises.
  """

  @type t :: %__MODULE__{actor: term(), tenant: term(), domain: module() | nil}

  defstruct [:actor, :tenant, :domain]

  @doc """
  A scope from a caller's options: `:actor`, `:tenant` and `:domain`, all optional.
  """
  @spec from_opts(keyword()) :: t()
  def from_opts(opts) do
    %__MODULE__{
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant),
      domain: Keyword.get(opts, :domain)
    }
  end

  @doc """
  A scope for an operation on a record already loaded.

  An explicit `:tenant` in `opts` wins; otherwise the tenant is the record's own
  `organization_id`, which is `nil` on a resource that is not tenant-scoped and
  therefore harmless there.
  """
  @spec from_record(map(), keyword()) :: t()
  def from_record(record, opts \\ []) do
    %__MODULE__{
      actor: Keyword.get(opts, :actor),
      tenant: Keyword.get(opts, :tenant) || tenant_of(record),
      domain: Keyword.get(opts, :domain) || domain_of(record)
    }
  end

  @doc """
  A scope from a LiveView's assigns.

  The two keys a Phoenix application already carries per request: `:current_user`
  and `:current_tenant`. Reading them here rather than in each LiveView is what
  keeps the editor's `use` macro free of any assumption about how the host names
  its scope -- it names these two, and a host that names them differently maps
  them once at mount.
  """
  @spec from_assigns(map()) :: t()
  def from_assigns(assigns) when is_map(assigns) do
    %__MODULE__{
      actor: Map.get(assigns, :current_user),
      tenant: Map.get(assigns, :current_tenant)
    }
  end

  @doc """
  A scope from a changeset already in flight.

  For the reads a change or validation makes against its own resource. The
  changeset knows both answers already — it was built with an actor and, if the
  resource is tenant-scoped, a tenant — and taking them from there is what stops
  `AssignVersion` from numbering a draft against every tenant's rows at once.
  """
  @spec from_changeset(Ash.Changeset.t()) :: t()
  def from_changeset(%Ash.Changeset{} = changeset) do
    %__MODULE__{
      actor: changeset.context[:private][:actor] || changeset.context[:actor],
      tenant: changeset.tenant
    }
  end

  @doc """
  A scope reconstructed from a job's args.

  This package enqueues nothing of its own, so there is no system actor here to
  name. It exists because the thing that evaluates a decision very often *is* a
  job — an `ash_bpmn` business rule task advancing on a worker, a host's nightly
  re-scoring run — and a job outlives the process that enqueued it, so the tenant
  has to travel in the payload or not at all. The actor is whatever the caller
  recorded and reconstructed for itself; nothing here can invent one.
  """
  @spec from_job(map(), keyword()) :: t()
  def from_job(args, opts \\ []) when is_map(args) do
    %__MODULE__{
      actor: Keyword.get(opts, :actor),
      tenant: args["tenant"],
      domain: args["domain"]
    }
  end

  @doc "A scope with neither actor nor tenant. For calls with genuinely nobody behind them."
  @spec system() :: t()
  def system, do: %__MODULE__{}

  @doc """
  The options every ash_decisions-internal Ash call passes.

  `extra` is appended, so a caller can add `:load`, `:action` and the like:

      Ash.read!(query, AshDecisions.Scope.engine(scope, load: [:definition]))

  `AshDecisions.Config.engine_actor/0` overrides the actor when a host has
  configured one; see there for the case that needs it. Otherwise see
  `AshDecisions.Checks.AshDecisionsInteraction` for what the context flag buys
  and, just as importantly, what it does not.
  """
  @spec engine(t(), keyword()) :: keyword()
  def engine(%__MODULE__{} = scope, extra \\ []) do
    [
      actor: AshDecisions.Config.engine_actor() || scope.actor,
      tenant: scope.tenant,
      context: %{private: %{ash_decisions?: true}}
    ] ++ extra
  end

  @doc """
  The tenant and domain as they travel in a job payload.

  Merged into the args map rather than passed alongside it, because job args are
  JSON and a keyword list is not. The actor is deliberately absent: serialising
  an actor is the host's decision, and a library that guessed at it would either
  leak whatever the actor struct happens to hold or silently drop the fields it
  did not know about.
  """
  @spec to_job_args(t(), map()) :: map()
  def to_job_args(%__MODULE__{} = scope, args) do
    args
    |> put_unless_nil("tenant", scope.tenant)
    |> put_unless_nil("domain", scope.domain && to_string(scope.domain))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp tenant_of(record) when is_map(record), do: Map.get(record, :organization_id)
  defp tenant_of(_), do: nil

  defp domain_of(%{__struct__: resource}) do
    Ash.Resource.Info.domain(resource)
  rescue
    _ -> nil
  end

  defp domain_of(_), do: nil
end

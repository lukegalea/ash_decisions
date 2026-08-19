defmodule AshDecisions.Resources.Definition do
  @moduledoc """
  Resource macro for DMN decision definitions.

  Builds an immutable, versioned definition resource. The host supplies at
  minimum `domain:` and `repo:`.

  The DMN document is the artifact. There is no second source of truth — no
  parallel rule table, no "simple mode" that writes different data — because the
  moment a decision has two representations someone has to keep them in step, and
  the whole point of holding rules as data is that nobody has to. `xml` is what an
  author edits and what an auditor is shown; `graph` is a derived snapshot and
  `content_hash` is what says the two belong together.

  ## Options

    * `:domain` — **required**. The Ash domain this resource belongs to.
    * `:repo` — **required**. The `AshPostgres.Repo` for this resource.
    * `:table` — table name (default `"dmn_definitions"`).
    * `:tenant?` — set `true` to add `organization_id` multitenancy (default `false`).
    * `:base` — the module to `use` in place of `Ash.Resource`, so the generated
      resource inherits a host application's base resource (ownership, audit,
      soft delete, tenancy, the policy set). See `AshDecisions.Resources.Base`.
    * `:base_opts` — options passed to `:base` verbatim, with `:domain` filled
      in. Ignored unless `:base` is set.
    * `:policies?` — emit the library bypass policy (default `true`). Setting it
      to `false` hands the host the entire policy set, including whatever this
      package needs to function. See `AshDecisions.Checks.AshDecisionsInteraction`.

  ## The lifecycle

  `draft → published → retired`, and nothing else. A draft is the only status
  whose XML can be changed, there is at most one draft per key (a partial unique
  index enforces it, so two designers cannot both open "the" draft), and
  publishing is refused while `errors` is non-empty.

  That last rule is the one that matters. `AshDecisions.Compiler` runs on every
  write, so a draft always carries the truth about whether it compiles; refusing
  to publish over a non-empty `errors` means a published definition is one the
  compiler accepted, and every caller downstream can rely on that without
  re-checking.

  ## Code interfaces (generated on the host module)

    * `create!/1` — a new draft at the next version for its key.
    * `save_xml!/2` — replace the XML of a draft, recompiling.
    * `publish!/1` — draft → published (`errors` must be `[]`).
    * `retire!/1` — published → retired.
    * `by_key_version/2` — fetch by identity; the bang form raises when there
      is no such version.
    * `latest_published/1` — the highest published version of a key, as a list.
  """

  defmacro __using__(opts) do
    repo = Keyword.fetch!(opts, :repo)
    table = Keyword.get(opts, :table, "dmn_definitions")
    tenant? = AshDecisions.Resources.Base.own_tenancy?(opts)
    policies? = Keyword.get(opts, :policies?, true)

    base_use = AshDecisions.Resources.Base.use_call(opts)

    quote do
      unquote(base_use)

      @ash_decisions_kind :definition

      def ash_decisions_kind, do: @ash_decisions_kind

      postgres do
        table(unquote(table))
        repo(unquote(repo))

        custom_indexes do
          # "At most one draft per key" is a rule about concurrent authors, so it
          # belongs in the database rather than in the validation that also
          # checks it. The validation gives a readable error; the index is what
          # makes the rule true.
          index([:key, :status], unique: true, where: "status = 'draft'")
        end
      end

      if unquote(tenant?) do
        multitenancy do
          strategy(:attribute)
          attribute(:organization_id)
          global?(true)
        end
      end

      # The library's own writes. Without this the resource has an authorizer
      # and -- unless the host adds policies -- no way to satisfy it, which is
      # the position that makes `authorize?: false` look reasonable. See
      # `AshDecisions.Checks.AshDecisionsInteraction` for what this replaces and
      # what it deliberately does not claim to be.
      if unquote(policies?) do
        policies do
          bypass AshDecisions.Checks.AshDecisionsInteraction do
            authorize_if(always())
          end
        end
      end

      attributes do
        uuid_primary_key(:id)

        attribute :key, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :name, :string do
          allow_nil?(false)
          public?(true)
        end

        attribute :version, :integer do
          allow_nil?(false)
          public?(true)
        end

        attribute :status, :atom do
          constraints(one_of: [:draft, :published, :retired])
          default(:draft)
          allow_nil?(false)
          public?(true)
        end

        # The DMN document, and the single artifact. `sensitive?` because a
        # decision table is where a business writes its pricing floors, its risk
        # thresholds and its escalation rules -- the contents are not secret from
        # the tenant, and they have no business appearing in a log line.
        attribute :xml, :string do
          allow_nil?(false)
          sensitive?(true)

          # Ash's `:string` trims by default. Not here: `content_hash` is what
          # says a snapshot and a document belong together, and an artifact the
          # store quietly rewrote before hashing is an artifact whose hash
          # identifies something the author never submitted. Stored byte for
          # byte, or the audit trail is about a different file.
          constraints(trim?: false)
        end

        # The compiled snapshot: decisions, clauses, hit policies and the FEEL
        # source text of every expression. Derived from `xml` on every write, so
        # it is never edited and never authoritative -- see `AshDecisions.Compiler`
        # on why it holds source text rather than a parsed AST.
        attribute :graph, :map do
          public?(true)
        end

        # `%{path:, message:}` per problem, from the compiler. Non-empty is a
        # perfectly valid state for a draft; it is what stops a publish.
        attribute :errors, {:array, :map} do
          default([])
          public?(true)
        end

        attribute :content_hash, :string do
          allow_nil?(false)
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

      identities do
        identity(:unique_key_version, [:key, :version])
      end

      actions do
        read :read do
          primary?(true)
        end

        read :latest_published do
          argument :key, :string do
            allow_nil?(false)
          end

          prepare(AshDecisions.Resources.Definition.FilterLatestPublished)
        end

        create :create do
          accept([:key, :name, :xml])

          change(AshDecisions.Resources.Definition.AssignVersion)
          change(AshDecisions.Resources.Definition.ComputeHash)
          change(AshDecisions.Resources.Definition.CompileXml)
          validate(AshDecisions.Resources.Definition.UniqueDraftCheck)
        end

        update :save_xml do
          accept([:xml])
          require_atomic?(false)

          validate(AshDecisions.Resources.Definition.StatusIsDraft)
          change(AshDecisions.Resources.Definition.ComputeHash)
          change(AshDecisions.Resources.Definition.CompileXml)
        end

        update :publish do
          accept([])
          require_atomic?(false)

          validate(AshDecisions.Resources.Definition.StatusIsDraft)
          validate(AshDecisions.Resources.Definition.ErrorsEmpty)
          change(set_attribute(:status, :published))
        end

        update :retire do
          accept([])
          require_atomic?(false)

          validate(AshDecisions.Resources.Definition.StatusIsPublished)
          change(set_attribute(:status, :retired))
        end
      end

      code_interface do
        define(:create, action: :create)
        define(:publish, action: :publish)
        define(:retire, action: :retire)
        define(:save_xml, action: :save_xml, args: [:xml])
        define(:by_key_version, action: :read, get_by: [:key, :version], get?: true)
        define(:latest_published, action: :latest_published, args: [:key])
      end
    end
  end
end

defmodule AshDecisions.Resources.Definition.FilterLatestPublished do
  @moduledoc false
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    key = Ash.Query.get_argument(query, :key)

    query
    |> Ash.Query.filter(status == :published)
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
  end
end

defmodule AshDecisions.Resources.Definition.AssignVersion do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)

    if is_nil(key) do
      changeset
    else
      max = max_version(changeset.resource, key, AshDecisions.Scope.from_changeset(changeset))
      Ash.Changeset.change_attribute(changeset, :version, max + 1)
    end
  end

  # Reads the resource it is changing, from inside an action the caller was
  # already authorized for -- so it runs as library work, marked for the bypass,
  # in the changeset's own tenant rather than unauthorized and rather than
  # globally.
  #
  # Deliberately not wrapped in a rescue. A read this package is not allowed to
  # make does not mean "there are no versions yet"; treating it as though it did
  # would number a new definition 1 and collide with the `[:key, :version]`
  # identity, reporting a duplicate-key error for what was really a policy
  # problem. Letting it raise says what actually happened.
  defp max_version(resource, key, scope) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key)
    |> Ash.Query.sort(version: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(AshDecisions.Scope.engine(scope))
    |> case do
      nil -> 0
      record -> record.version
    end
  end
end

defmodule AshDecisions.Resources.Definition.ComputeHash do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :xml) do
      nil ->
        changeset

      xml ->
        hash = :crypto.hash(:sha256, xml) |> Base.encode16(case: :lower)
        Ash.Changeset.change_attribute(changeset, :content_hash, hash)
    end
  end
end

defmodule AshDecisions.Resources.Definition.CompileXml do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :xml) do
      nil ->
        changeset

      xml ->
        case AshDecisions.Compiler.compile(xml) do
          {:ok, graph} ->
            changeset
            |> Ash.Changeset.change_attribute(:graph, graph)
            |> Ash.Changeset.change_attribute(:errors, [])

          # A draft that does not compile is stored, not rejected. An author
          # mid-edit has a document that does not compile most of the time, and
          # a designer that refuses to save until it does is a designer nobody
          # can use. `publish` is where the refusal belongs.
          {:error, errors} ->
            changeset
            |> Ash.Changeset.change_attribute(:graph, nil)
            |> Ash.Changeset.change_attribute(:errors, errors)
        end
    end
  end
end

defmodule AshDecisions.Resources.Definition.ErrorsEmpty do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :errors) == [] do
      :ok
    else
      {:error, field: :errors, message: "cannot publish a definition with compile errors"}
    end
  end
end

defmodule AshDecisions.Resources.Definition.UniqueDraftCheck do
  @moduledoc false
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    key = Ash.Changeset.get_attribute(changeset, :key)

    cond do
      is_nil(key) ->
        :ok

      draft_exists?(changeset, key) ->
        {:error, field: :key, message: "a draft already exists for this key"}

      true ->
        :ok
    end
  end

  # The partial unique index is what makes this true; this is what makes it
  # readable. Same tenant, same bypass, same reasoning as `AssignVersion`.
  defp draft_exists?(changeset, key) do
    changeset.resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^key and status == :draft)
    |> Ash.read_one!(AshDecisions.Scope.engine(AshDecisions.Scope.from_changeset(changeset)))
    |> is_nil()
    |> Kernel.not()
  end
end

defmodule AshDecisions.Resources.Definition.StatusIsDraft do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :status) == :draft do
      :ok
    else
      {:error, field: :status, message: "can only perform this action on a draft definition"}
    end
  end
end

defmodule AshDecisions.Resources.Definition.StatusIsPublished do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :status) == :published do
      :ok
    else
      {:error, field: :status, message: "can only retire a published definition"}
    end
  end
end

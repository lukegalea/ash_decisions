# A second instantiation of both resource macros, this time with `tenant?: true`,
# against a second, tenant-scoped copy of the tables.
#
# `ash_bpmn` shipped a `tenant?:` option that generated an `organization_id`
# attribute and a multitenancy strategy against tables that had no such column,
# while the facade discarded the `:tenant` option it documented. Three facts,
# each individually invisible, that jointly meant the feature did not work. The
# only thing that would have caught it is a suite that runs against tenanted
# tables, so this package has one from the start.
#
# These modules deliberately carry **no policies of their own**, so the tenancy
# suite is also, incidentally, a test that this package's own calls are
# recognised by the bypass the macros generate. A host would add its policies
# here.

defmodule AshDecisions.TenantTest.Definition do
  @moduledoc false
  use AshDecisions.Resources.Definition,
    domain: AshDecisions.TenantTest.Domain,
    repo: AshDecisions.TestRepo,
    table: "tenant_dmn_definitions",
    tenant?: true
end

defmodule AshDecisions.TenantTest.Evaluation do
  @moduledoc false
  use AshDecisions.Resources.Evaluation,
    domain: AshDecisions.TenantTest.Domain,
    repo: AshDecisions.TestRepo,
    definition: AshDecisions.TenantTest.Definition,
    table: "tenant_dmn_evaluations",
    tenant?: true
end

defmodule AshDecisions.TenantTest.Domain do
  @moduledoc false
  use Ash.Domain

  resources do
    resource(AshDecisions.TenantTest.Definition)
    resource(AshDecisions.TenantTest.Evaluation)
  end
end

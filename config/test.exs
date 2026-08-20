import Config

# The test repo. Postgres connection details come from the environment so both
# devenv (dynamic port, read from the cluster's postgresql.conf) and CI (fixed
# port) work without editing this file. Same pattern as ash_bpmn.
config :ash_decisions, AshDecisions.TestRepo,
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  database: "ash_decisions_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online()

# The web test endpoint (test/support/web_endpoint.ex). Config lives here rather
# than in a compile-time Application.put_env in the module body, because that
# only executes on fresh compilation and never from cached beams.
config :ash_decisions, AshDecisions.Web.TestEndpoint,
  server: false,
  pubsub_server: AshDecisions.Web.TestPubSub,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: String.duplicate("b", 32)],
  render_errors: [formats: [html: {AshDecisions.ErrorView, :render, []}], layout: false]

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false
config :ash, disable_async?: true

config :logger, level: :warning

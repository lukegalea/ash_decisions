import Config

# `mix ash_decisions.tck` runs in :dev and touches no database, so this exists
# only so that `import_config` in config.exs has something to find and so a
# `mix ecto.*` invocation in dev does not fail on a missing repo config.
config :ash_decisions, AshDecisions.TestRepo,
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  database: "ash_decisions_dev",
  pool_size: 5

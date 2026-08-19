import Config

# This config exists for ash_decisions' OWN dev and test runs. It is not shipped --
# `files:` in mix.exs excludes it -- and a consuming application configures its own
# repo and domains. Same pattern as ash_bpmn.
config :ash_decisions, ecto_repos: [AshDecisions.TestRepo]

if config_env() in [:dev, :test] do
  import_config "#{config_env()}.exs"
end

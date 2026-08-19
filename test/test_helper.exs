# Create the test database if it is not there yet.
AshDecisions.TestRepo.__adapter__().storage_up(AshDecisions.TestRepo.config())

{:ok, _} = AshDecisions.TestRepo.start_link()

migration_path = Path.expand("priv/test_repo/migrations")

if File.dir?(migration_path) do
  Ecto.Migrator.run(AshDecisions.TestRepo, migration_path, :up, all: true)
end

Ecto.Adapters.SQL.Sandbox.mode(AshDecisions.TestRepo, :manual)

ExUnit.start()

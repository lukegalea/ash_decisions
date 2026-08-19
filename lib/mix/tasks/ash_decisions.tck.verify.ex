defmodule Mix.Tasks.AshDecisions.Tck.Verify do
  @shortdoc "Check that the vendored DMN TCK corpus is unmodified"

  @moduledoc """
  Recomputes the SHA-256 of every vendored TCK file and compares it against
  `priv/tck/VENDORED_FILES.sha256`.

  The corpus is third-party content under a **share-alike** licence, so a modified test case
  is a derivative work. It is also the thing our conformance claim rests on: editing a test
  to make it pass would be undetectable by any other means. This task makes it a build
  failure instead.

  Re-vendoring from a newer upstream commit is a deliberate act — replace the directories,
  update `PINNED_COMMIT`, and regenerate the manifest as part of that same commit.
  """

  use Mix.Task

  @manifest "VENDORED_FILES.sha256"

  # Ours, not upstream's: the manifest itself, the commit pointer, and the attribution note.
  # Everything else under priv/tck is vendored and must not change.
  @ours [@manifest, "PINNED_COMMIT", "ATTRIBUTION.md"]

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    dir = AshDecisions.Tck.Runner.corpus_dir()
    manifest = Path.join(dir, @manifest)

    unless File.exists?(manifest) do
      Mix.raise("no #{@manifest} in #{dir} — the vendored corpus is unverifiable")
    end

    recorded = read_manifest(manifest)
    actual = hash_tree(dir)

    changed = for {f, h} <- actual, Map.has_key?(recorded, f), recorded[f] != h, do: f
    added = for {f, _} <- actual, not Map.has_key?(recorded, f), do: f
    removed = for {f, _} <- recorded, not Map.has_key?(actual, f), do: f

    case {changed, added, removed} do
      {[], [], []} ->
        Mix.shell().info("DMN TCK corpus verified: #{map_size(actual)} files unmodified")

      _ ->
        Mix.raise("""
        the vendored DMN TCK corpus has been modified.

          modified: #{inspect(changed, limit: 10)}
          added:    #{inspect(added, limit: 10)}
          removed:  #{inspect(removed, limit: 10)}

        See priv/tck/ATTRIBUTION.md — this corpus is share-alike licensed and must stay
        byte-identical to its pinned upstream commit.
        """)
    end
  end

  defp read_manifest(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [hash, file] = String.split(line, ~r/\s+/, parts: 2)
      {String.trim_leading(file, "*"), hash}
    end)
  end

  defp hash_tree(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.reject(&(Path.basename(&1) in @ours))
    |> Map.new(fn file ->
      {"./" <> Path.relative_to(file, dir), file |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)}
    end)
  end
end

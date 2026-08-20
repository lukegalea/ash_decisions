defmodule AshDecisions.MixProject do
  use Mix.Project

  @version "0.1.0"

  @description """
  DMN decisions as versioned Ash resources: a DMN document compiled and verified into an
  immutable snapshot, evaluated by a native FEEL engine, with a dmn-js designer.
  """

  def project do
    [
      app: :ash_decisions,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      description: @description,
      package: package(),
      source_url: "https://github.com/lukegalea/ash_decisions",
      homepage_url: "https://github.com/lukegalea/ash_decisions"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `:xmerl` is OTP's XML parser -- the only XML dependency, for both the DMN
  # compiler and the TCK expectation files. No hex package needed, which is the
  # same choice ash_bpmn made.
  def application do
    [extra_applications: [:logger, :xmerl, :crypto]]
  end

  defp package do
    [
      name: :ash_decisions,
      licenses: ["MIT"],
      maintainers: ["Luke Galea <luke@ideaforge.org>"],
      # Only paths that exist. `documentation/` and `CHANGELOG.md` were listed
      # before either was written; Hex warns on a missing file rather than
      # failing, so the list quietly described a package that was never built.
      files: ~w(lib priv/js LICENSE README.md
        usage-rules.md mix.exs .formatter.exs),
      links: %{"GitHub" => "https://github.com/lukegalea/ash_decisions"}
    ]
  end

  defp deps do
    [
      # The decision engine itself. `boxic_dmn` is a native Elixir DMN 1.5
      # loader/validator/evaluator and `boxic_feel` is its FEEL parser and
      # evaluator; both are Apache-2.0. See docs/adr -- this package is an Ash
      # layer over them (versioning, tenancy, policy, audit, publish-time
      # analysis, the designer), not a second engine.
      {:boxic_dmn, "~> 0.3"},
      {:boxic_feel, "~> 0.2"},
      {:decimal, "~> 3.1"},
      {:jason, "~> 1.2"},
      # The Ash layer. `ash_postgres` is the data layer every generated resource
      # declares unless a host's base resource declares one instead.
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      # The dmn-js editor LiveView. A hard dependency rather than optional, the
      # same way ash_bpmn declares it: the editor is half of what this package is
      # for, and an optional dependency that the shipped module needs anyway buys
      # a compile-time failure instead of a resolvable one.
      {:phoenix_live_view, "~> 1.0"},
      # dev/test only
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      # LiveView tests need an HTML query engine. `lazy_html` rather than floki
      # because it is what phoenix_live_view 1.x selects against.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      credo: "credo --strict",
      test: ["test"]
    ]
  end
end

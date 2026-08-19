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
      files: ~w(lib priv/js documentation CHANGELOG.md LICENSE README.md
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
      {:jason, "~> 1.2"}
    ]
  end
end

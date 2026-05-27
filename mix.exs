defmodule Mob.Mesh.MixProject do
  use Mix.Project

  @github_url "https://github.com/dl-alexandre/mob_mesh"
  @version "0.1.0"
  @description "Multi-hop mesh transport layer for mob transport plugins."

  def project do
    [
      app: :mob_mesh,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Coverage is reported in the umbrella summary but not gated here; this
      # plugin is published independently (threshold 0 => summary only, never fails).
      test_coverage: [summary: [threshold: 0]],
      deps: deps(),
      dialyzer: dialyzer(),
      description: @description,
      package: package(),
      source_url: @github_url,
      homepage_url: @github_url,
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/ROUTING_STRATEGY.md",
          "docs/MIGRATION.md",
          "docs/SECURITY.md",
          "docs/PERFORMANCE.md",
          "CHANGELOG.md",
          "LICENSE"
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry]
    ]
  end

  defp deps do
    transport_dep() ++
      [
        {:telemetry, "~> 1.3"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.40.2", only: :dev, runtime: false}
      ]
  end

  # Mesh has a hard runtime dependency on Mob.Transport.Adapter. Resolve it from
  # the sibling app inside the umbrella; fall back to the source repo for a
  # standalone checkout (mob_transport is not yet published to Hex).
  defp transport_dep do
    if File.exists?(Path.expand("../mob_transport/mix.exs", __DIR__)),
      do: [{:mob_transport, in_umbrella: true}],
      else: [{:mob_transport, github: "dl-alexandre/mob_transport"}]
  end

  defp dialyzer do
    [
      plt_local_path: "_build/plts",
      plt_core_path: "_build/plts",
      plt_add_apps: [:mix, :ex_unit],
      flags: [:error_handling, :unknown, :unmatched_returns]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Changelog" => "#{@github_url}/blob/main/CHANGELOG.md",
        "mob" => "https://github.com/GenericJam/mob",
        "mob_dev" => "https://github.com/GenericJam/mob_dev"
      },
      files: ~w(
        lib
        docs
        .github/workflows
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
      )
    ]
  end
end

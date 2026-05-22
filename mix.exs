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
    [
      {:mob_transport, github: "dl-alexandre/mob_transport"},
      {:telemetry, "~> 1.3"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40.2", only: :dev, runtime: false}
    ]
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

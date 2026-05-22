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
          "CHANGELOG.md",
          "LICENSE"
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mob_transport, github: "dl-alexandre/mob_transport"},
      {:ex_doc, "~> 0.40.2", only: :dev, runtime: false}
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
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
      )
    ]
  end
end

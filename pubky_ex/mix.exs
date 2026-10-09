defmodule Pubky.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/secondl1ght/pubky-rooms"

  def project do
    [
      app: :pubky,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "pubky_ex",
      description:
        "Pure-Elixir client for the Pubky protocol: identity, PKARR discovery, grant auth, homeserver storage, and event streams.",
      source_url: @source_url,
      package: [licenses: ["MIT"], links: %{"GitHub" => @source_url}],
      docs: [main: "Pubky", extras: ["README.md"]],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl],
      mod: {Pubky.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:kcl, "~> 1.5"},
      {:bypass, "~> 2.1", only: :test},
      {:plug_cowboy, "~> 2.7", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end

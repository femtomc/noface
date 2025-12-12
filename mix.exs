defmodule NofaceElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :noface_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Noface.Application, []}
    ]
  end

  defp escript do
    [main_module: Noface.CLI]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # JSON parsing
      {:jason, "~> 1.4"},
      # Streaming JSON parser
      {:jaxon, "~> 2.0"},
      # TOML config parsing
      {:toml, "~> 0.7"},
      # SQLite for transcripts (Ecto)
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      # Embedded key-value store for state
      {:cubdb, "~> 2.0"},
      # HTTP client for GitHub/Gitea APIs
      {:req, "~> 0.5"},
      # Terminal UI
      {:owl, "~> 0.12"},
      # Telemetry for observability
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      # File system watcher for hot reload
      {:file_system, "~> 1.0"}
    ]
  end

  defp aliases do
    []
  end
end

defmodule NofaceElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :noface_elixir,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      listeners: [Phoenix.CodeReloader]
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
      # Phoenix web framework
      {:phoenix, "~> 1.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:plug_cowboy, "~> 2.7"},
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
end

defmodule Noface.CLI do
  @moduledoc """
  Command-line interface for noface.

  Provides the main entry point and subcommands.
  """

  alias Noface.Core.{Config, Loop}
  alias Noface.Server.Web

  @doc """
  Main entry point for the escript.
  """
  def main(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        strict: [
          config: :string,
          max_iterations: :integer,
          issue: :string,
          dry_run: :boolean,
          no_planner: :boolean,
          planner_interval: :integer,
          event_driven_planner: :boolean,
          planner_directions: :string,
          no_quality: :boolean,
          quality_interval: :integer,
          monowiki_vault: :string,
          stream_json: :boolean,
          raw: :boolean,
          verbose: :boolean,
          agent_timeout: :integer,
          port: :integer,
          force: :boolean,
          skip_deps: :boolean,
          help: :boolean
        ],
        aliases: [
          c: :config,
          n: :max_iterations,
          i: :issue,
          p: :port,
          h: :help,
          v: :verbose
        ]
      )

    if opts[:help] do
      print_help()
    else
      case args do
        [] -> run_command(:run, opts)
        ["init" | _] -> run_command(:init, opts)
        ["serve" | _] -> run_command(:serve, opts)
        ["doctor" | _] -> run_command(:doctor, opts)
        ["sync" | _] -> run_command(:sync, opts)
        [cmd | _] -> IO.puts("Unknown command: #{cmd}\nRun 'noface --help' for usage.")
      end
    end
  end

  defp run_command(:run, opts) do
    IO.puts("\e[1;34m[NOFACE]\e[0m Starting orchestrator...")

    # Load configuration
    config_path = opts[:config] || ".noface.toml"

    config =
      case Config.load_from_file(config_path) do
        {:ok, cfg} -> cfg
        {:error, _} -> Config.default()
      end

    # Apply command-line overrides
    config = apply_cli_overrides(config, opts)

    # Start the application
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    # Run the main loop
    case Loop.run(config) do
      :ok ->
        IO.puts("\e[1;32m[NOFACE]\e[0m Orchestrator finished successfully")

      {:error, reason} ->
        IO.puts("\e[1;31m[NOFACE]\e[0m Orchestrator failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_command(:init, opts) do
    IO.puts("\e[1;34m[NOFACE]\e[0m Initializing project...")

    force = opts[:force] || false
    skip_deps = opts[:skip_deps] || false

    # Check if already initialized
    if File.exists?(".noface.toml") and not force do
      IO.puts("\e[1;33m[NOFACE]\e[0m .noface.toml already exists. Use --force to overwrite.")
      System.halt(1)
    end

    # Create default config
    default_config = """
    [project]
    name = "#{Path.basename(File.cwd!())}"
    build = "make build"
    test = "make test"

    [agents]
    implementer = "claude"
    reviewer = "codex"
    timeout_seconds = 900
    num_workers = 5

    [passes]
    planner_enabled = true
    planner_interval = 5
    planner_mode = "interval"
    quality_enabled = true
    quality_interval = 10

    [tracker]
    type = "beads"
    sync_to_github = false
    """

    File.write!(".noface.toml", default_config)
    IO.puts("\e[1;32m[NOFACE]\e[0m Created .noface.toml")

    # Check dependencies unless skipped
    unless skip_deps do
      check_dependencies()
    end

    # Initialize beads if not present
    unless File.exists?(".beads") do
      case System.cmd("bd", ["init"], stderr_to_stdout: true) do
        {_, 0} -> IO.puts("\e[1;32m[NOFACE]\e[0m Initialized beads issue tracker")
        _ -> IO.puts("\e[1;33m[NOFACE]\e[0m Could not initialize beads (bd command not found)")
      end
    end

    IO.puts("\e[1;32m[NOFACE]\e[0m Project initialized successfully!")
  end

  defp run_command(:serve, opts) do
    api_port = opts[:port] || 3000
    IO.puts("\e[1;34m[NOFACE]\e[0m Starting servers...")

    {:ok, _} = Application.ensure_all_started(:noface_elixir)
    {:ok, _} = Web.start(port: api_port)

    IO.puts("\e[1;32m[NOFACE]\e[0m Dashboard running at http://localhost:4000")
    IO.puts("\e[1;32m[NOFACE]\e[0m API server running at http://localhost:#{api_port}")
    IO.puts("Press Ctrl+C to stop")

    # Keep running
    Process.sleep(:infinity)
  end

  defp run_command(:doctor, _opts) do
    IO.puts("\e[1;34m[NOFACE]\e[0m Running health check...")

    checks = [
      {:noface_config, File.exists?(".noface.toml")},
      {:beads_init, File.exists?(".beads")},
      {:claude_installed, command_exists?("claude")},
      {:codex_installed, command_exists?("codex")},
      {:jj_installed, command_exists?("jj")},
      {:bd_installed, command_exists?("bd")},
      {:gh_installed, command_exists?("gh")}
    ]

    Enum.each(checks, fn {name, passed} ->
      status = if passed, do: "\e[32m\u2713\e[0m", else: "\e[31m\u2717\e[0m"
      IO.puts("  #{status} #{name}")
    end)

    all_passed = Enum.all?(checks, fn {_, passed} -> passed end)

    if all_passed do
      IO.puts("\n\e[1;32m[NOFACE]\e[0m All checks passed!")
    else
      IO.puts("\n\e[1;33m[NOFACE]\e[0m Some checks failed. Run 'noface init' to fix.")
    end
  end

  defp run_command(:sync, opts) do
    IO.puts("\e[1;34m[NOFACE]\e[0m Syncing issues...")

    dry_run = opts[:dry_run] || false

    config =
      case Config.load_from_file(".noface.toml") do
        {:ok, cfg} -> cfg
        {:error, _} -> Config.default()
      end

    case Noface.Integrations.IssueSync.sync(config.sync_provider, dry_run: dry_run) do
      {:ok, result} ->
        IO.puts("\e[1;32m[NOFACE]\e[0m Sync complete:")
        IO.puts("  Created: #{result.created}")
        IO.puts("  Updated: #{result.updated}")
        IO.puts("  Skipped: #{result.skipped}")

        if result.errors > 0 do
          IO.puts("  \e[33mErrors: #{result.errors}\e[0m")
        end

      {:error, reason} ->
        IO.puts("\e[1;31m[NOFACE]\e[0m Sync failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp apply_cli_overrides(config, opts) do
    config
    |> maybe_override(:max_iterations, opts[:max_iterations])
    |> maybe_override(:specific_issue, opts[:issue])
    |> maybe_override(:dry_run, opts[:dry_run])
    # Only override enable_planner if --no-planner flag was explicitly provided
    |> maybe_override(:enable_planner, if(Keyword.has_key?(opts, :no_planner), do: false))
    |> maybe_override(:planner_interval, opts[:planner_interval])
    |> maybe_override(:planner_mode, if(opts[:event_driven_planner], do: :event_driven))
    |> maybe_override(:planner_directions, opts[:planner_directions])
    # Only override enable_quality if --no-quality flag was explicitly provided
    |> maybe_override(:enable_quality, if(Keyword.has_key?(opts, :no_quality), do: false))
    |> maybe_override(:quality_interval, opts[:quality_interval])
    |> maybe_override(:monowiki_vault, opts[:monowiki_vault])
    |> maybe_override(
      :output_format,
      cond do
        opts[:stream_json] -> :stream_json
        opts[:raw] -> :raw
        true -> nil
      end
    )
    |> maybe_override(:verbose, opts[:verbose])
    |> maybe_override(:agent_timeout_seconds, opts[:agent_timeout])
  end

  defp maybe_override(config, _key, nil), do: config
  defp maybe_override(config, key, value), do: Map.put(config, key, value)

  defp check_dependencies do
    deps = [
      {"claude", "Implementation agent (Claude Code)"},
      {"codex", "Review agent (Codex CLI)"},
      {"jj", "Version control (Jujutsu)"},
      {"bd", "Issue tracker (Beads)"},
      {"gh", "GitHub CLI (optional)"}
    ]

    IO.puts("\nChecking dependencies:")

    Enum.each(deps, fn {cmd, desc} ->
      if command_exists?(cmd) do
        IO.puts("  \e[32m\u2713\e[0m #{cmd} - #{desc}")
      else
        IO.puts("  \e[33m\u2717\e[0m #{cmd} - #{desc} (not found)")
      end
    end)

    IO.puts("")
  end

  defp command_exists?(cmd) do
    case System.cmd("which", [cmd], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp print_help do
    IO.puts("""
    noface - Autonomous agent orchestrator

    USAGE:
      noface [OPTIONS]            Run the agent loop
      noface init [OPTIONS]       Initialize a new project
      noface serve [OPTIONS]      Start dashboard + API servers
      noface doctor               Check system health
      noface sync [OPTIONS]       Sync issues to external tracker

    OPTIONS:
      -c, --config PATH           Path to config file (default: .noface.toml)
      -n, --max-iterations N      Maximum iterations (0 = unlimited)
      -i, --issue ID              Work on a specific issue only
      --dry-run                   Don't execute, just show what would happen
      --no-planner                Disable planner passes
      --planner-interval N        Run planner every N iterations
      --event-driven-planner      Run planner only when needed
      --planner-directions TEXT   User directions for the planner
      --no-quality                Disable quality review passes
      --quality-interval N        Run quality review every N iterations
      --monowiki-vault PATH       Path to monowiki vault
      --stream-json               Output raw JSON streaming
      --raw                       Plain text output without formatting
      -v, --verbose               Enable verbose logging
      --agent-timeout N           Agent timeout in seconds (default: 900)
      -p, --port N                API server port (default: 3000)
      --force                     Overwrite existing files
      --skip-deps                 Skip dependency checks
      -h, --help                  Show this help message

    EXAMPLES:
      noface                      Run orchestrator with default settings
      noface init                 Initialize a new noface project
      noface serve                Start dashboard (4000) + API server (3000)
      noface --issue BUG-123      Work on specific issue
      noface --max-iterations 10  Run 10 iterations then stop

    For more information, visit: https://github.com/anthropics/noface
    """)
  end
end

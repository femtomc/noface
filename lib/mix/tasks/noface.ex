defmodule Mix.Tasks.Noface do
  @moduledoc """
  Mix tasks for interacting with a running noface server.

  ## Available commands

      mix noface.init        # Initialize noface in current directory
      mix noface.start       # Start the persistent server
      mix noface.status      # Show server status
      mix noface.pause       # Pause the loop
      mix noface.resume      # Resume the loop
      mix noface.interrupt   # Interrupt current work
      mix noface.issue       # File a new issue
      mix noface.update      # Update CLI tools

  The noface server runs as a persistent OTP application.
  These commands send messages to the running server.
  """
  use Mix.Task

  @shortdoc "Noface orchestrator commands"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("""
    Noface - Autonomous Agent Orchestrator

    Available commands:
      mix noface.init        Initialize noface and install tools
      mix noface.start       Start the persistent server
      mix noface.status      Show server status
      mix noface.pause       Pause the loop (finish current work)
      mix noface.resume      Resume after pause
      mix noface.interrupt   Cancel current work
      mix noface.issue       File a new issue
      mix noface.update      Update CLI tools

    Run `mix help noface.<command>` for details.
    """)
  end
end

defmodule Mix.Tasks.Noface.Init do
  @moduledoc """
  Initialize noface in the current directory.

  ## Usage

      mix noface.init [--force]

  Options:
    --force   Reinstall tools even if already installed

  This will:
  1. Create `.noface/` directory structure
  2. Install local CLI tools (claude, codex, bd, gh, jj)
  3. Create default `.noface.toml` config if not present

  Tools are installed to `.noface/bin/` and `.noface/node_modules/`.
  This gives noface control over tool versions and enables auto-updates.
  """
  use Mix.Task

  @shortdoc "Initialize noface and install tools"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean])
    force = opts[:force] || false

    Mix.shell().info("Initializing noface...")

    # Ensure application dependencies are available
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    # Initialize tools
    case Noface.Tools.init(force: force) do
      :ok ->
        Mix.shell().info("")
        Mix.shell().info("Tools installed to .noface/bin/")

        # Show installed versions
        versions = Noface.Tools.versions()

        if map_size(versions) > 0 do
          Mix.shell().info("")
          Mix.shell().info("Installed versions:")

          Enum.each(versions, fn {tool, version} ->
            Mix.shell().info("  #{tool}: #{version}")
          end)
        end

        # Create default config if not present
        create_default_config()

        Mix.shell().info("")
        Mix.shell().info("Done! Run `mix noface.start --open` to start the server.")

      {:error, reason} ->
        Mix.shell().error("Initialization failed: #{inspect(reason)}")
    end
  end

  defp create_default_config do
    config_path = ".noface.toml"

    unless File.exists?(config_path) do
      project_name =
        File.cwd!()
        |> Path.basename()
        |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

      config = """
      # Noface configuration
      # See: https://github.com/femtomc/noface

      [project]
      name = "#{project_name}"
      build = "mix compile"
      test = "mix test"

      [agents]
      implementer = "claude"
      reviewer = "codex"
      timeout_seconds = 900
      num_workers = 3

      [passes]
      planner_enabled = true
      planner_interval = 5
      planner_mode = "event_driven"
      quality_enabled = true
      quality_interval = 10

      [tracker]
      type = "beads"
      sync_to_github = false

      # [monowiki]
      # vault = "wiki/vault"
      """

      File.write!(config_path, config)
      Mix.shell().info("Created #{config_path}")
    end
  end
end

defmodule Mix.Tasks.Noface.Start do
  @moduledoc """
  Start the noface server.

  ## Usage

      mix noface.start [--config PATH] [--open]

  Options:
    --config PATH   Path to .noface.toml config file (default: .noface.toml)
    --open          Open the dashboard in your browser automatically

  The server runs as a persistent OTP application and processes issues
  from your beads backlog. Use other `mix noface.*` commands to interact
  with the running server.
  """
  use Mix.Task

  @shortdoc "Start the noface server"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [config: :string, open: :boolean])
    config_path = opts[:config] || ".noface.toml"
    open_browser? = opts[:open] || false

    Mix.shell().info("Starting noface server...")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    # Open browser if requested (after small delay for server to be ready)
    if open_browser? do
      Task.start(fn ->
        Process.sleep(1000)
        open_browser("http://localhost:4000")
      end)
    end

    # Load config and start the loop
    case Noface.Core.Config.load(config_path) do
      {:ok, config} ->
        case Noface.Core.Loop.start(config) do
          :ok ->
            Mix.shell().info("Noface server started for #{config.project_name}")
            Mix.shell().info("Dashboard: http://localhost:4000")
            # Keep running
            Process.sleep(:infinity)

          {:error, reason} ->
            Mix.shell().error("Failed to start: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to load config: #{inspect(reason)}")
    end
  end

  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
    end
  end
end

defmodule Mix.Tasks.Noface.Status do
  @moduledoc """
  Show the status of the running noface server.

  ## Usage

      mix noface.status

  Displays:
    - Server uptime
    - Loop status (running/paused/idle)
    - Current iteration
    - Issue counts by status
    - Active workers
  """
  use Mix.Task

  @shortdoc "Show noface server status"

  @impl Mix.Task
  def run(_args) do
    ensure_started()

    case Noface.Server.Command.status() do
      status ->
        Mix.shell().info("""
        Noface Status
        =============

        Server:
          Started: #{status.server.started_at}
          Uptime:  #{format_duration(status.server.uptime_seconds)}

        Loop:
          Running: #{status.loop.running}
          Paused:  #{status.loop.paused}
          Iteration: #{status.loop.iteration}
          Current Work: #{inspect(status.loop.current_work) || "none"}

        Issues:
          Total:       #{status.state.total_issues}
          Pending:     #{status.state.pending}
          In Progress: #{status.state.in_progress}
          Completed:   #{status.state.completed}
          Failed:      #{status.state.failed}

        Workers:
          Active: #{status.workers[:active_count] || 0}
        """)
    end
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:noface_elixir)
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
  end
end

defmodule Mix.Tasks.Noface.Pause do
  @moduledoc """
  Pause the noface loop.

  ## Usage

      mix noface.pause

  The loop will finish any current work and then stop picking up new work.
  Use `mix noface.resume` to continue.
  """
  use Mix.Task

  @shortdoc "Pause the noface loop"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    case Noface.Server.Command.pause() do
      :ok ->
        Mix.shell().info("Loop paused. Use `mix noface.resume` to continue.")

      {:error, :already_paused} ->
        Mix.shell().info("Loop is already paused.")

      {:error, :not_running} ->
        Mix.shell().error("Loop is not running.")
    end
  end
end

defmodule Mix.Tasks.Noface.Resume do
  @moduledoc """
  Resume the noface loop after pause.

  ## Usage

      mix noface.resume
  """
  use Mix.Task

  @shortdoc "Resume the noface loop"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    case Noface.Server.Command.resume() do
      :ok ->
        Mix.shell().info("Loop resumed.")

      {:error, :not_paused} ->
        Mix.shell().info("Loop is not paused.")
    end
  end
end

defmodule Mix.Tasks.Noface.Interrupt do
  @moduledoc """
  Interrupt current work immediately.

  ## Usage

      mix noface.interrupt

  This kills any active workers and returns the loop to idle.
  The interrupted issue will be retried later.
  """
  use Mix.Task

  @shortdoc "Interrupt current noface work"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    case Noface.Server.Command.interrupt() do
      :ok ->
        Mix.shell().info("Interrupted current work.")
    end
  end
end

defmodule Mix.Tasks.Noface.Issue do
  @moduledoc """
  File a new issue via beads.

  ## Usage

      mix noface.issue "Issue title" [--body BODY] [--labels LABELS]

  Options:
    --body BODY      Issue description
    --labels LABELS  Comma-separated labels

  The issue will be added to the beads backlog and picked up by the loop.
  """
  use Mix.Task

  @shortdoc "File a new issue"

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [body: :string, labels: :string])

    title =
      case rest do
        [t | _] -> t
        [] -> Mix.raise("Usage: mix noface.issue \"Issue title\" [--body BODY]")
      end

    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    labels =
      if opts[:labels] do
        String.split(opts[:labels], ",") |> Enum.map(&String.trim/1)
      else
        nil
      end

    case Noface.Server.Command.file_issue(title, body: opts[:body], labels: labels) do
      {:ok, issue_id} ->
        Mix.shell().info("Created issue: #{issue_id}")

      {:error, reason} ->
        Mix.shell().error("Failed to create issue: #{reason}")
    end
  end
end

defmodule Mix.Tasks.Noface.Inspect do
  @moduledoc """
  Inspect an issue's current state.

  ## Usage

      mix noface.inspect ISSUE_ID
  """
  use Mix.Task

  @shortdoc "Inspect an issue"

  @impl Mix.Task
  def run(args) do
    issue_id =
      case args do
        [id | _] -> id
        [] -> Mix.raise("Usage: mix noface.inspect ISSUE_ID")
      end

    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    case Noface.Server.Command.inspect_issue(issue_id) do
      {:ok, issue} ->
        Mix.shell().info("""
        Issue: #{issue.id}
        Status: #{issue.status}
        Attempts: #{issue.attempt_count}
        Assigned Worker: #{issue.assigned_worker || "none"}
        """)

      {:error, :not_found} ->
        Mix.shell().error("Issue not found: #{issue_id}")
    end
  end
end

defmodule Mix.Tasks.Noface.Update do
  @moduledoc """
  Update CLI tools to their latest versions.

  ## Usage

      mix noface.update [TOOL]

  Examples:
      mix noface.update         # Check and update all tools
      mix noface.update claude  # Update only claude
      mix noface.update --check # Just check, don't update

  Options:
    --check   Only check for updates, don't install them
  """
  use Mix.Task

  @shortdoc "Update CLI tools"

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [check: :boolean])
    check_only = opts[:check] || false

    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    case rest do
      [] ->
        # Update all
        Mix.shell().info("Checking for updates...")

        case Noface.Tools.check_updates() do
          {:ok, updates} when map_size(updates) == 0 ->
            Mix.shell().info("All tools are up to date!")

          {:ok, updates} ->
            Mix.shell().info("Updates available:")

            Enum.each(updates, fn {tool, info} ->
              Mix.shell().info("  #{tool}: #{info.current} -> #{info.latest}")
            end)

            unless check_only do
              Mix.shell().info("")
              Mix.shell().info("Installing updates...")
              Noface.Tools.update_all()
              Mix.shell().info("Done!")
            end

          {:error, reason} ->
            Mix.shell().error("Failed to check updates: #{inspect(reason)}")
        end

      [tool | _] ->
        tool_atom = String.to_atom(tool)

        if check_only do
          Mix.shell().info("Checking #{tool}...")

          case Noface.Tools.check_updates() do
            {:ok, updates} ->
              case Map.get(updates, tool_atom) || Map.get(updates, tool) do
                nil ->
                  Mix.shell().info("#{tool} is up to date")

                info ->
                  Mix.shell().info("#{tool}: #{info.current} -> #{info.latest}")
              end

            {:error, reason} ->
              Mix.shell().error("Failed: #{inspect(reason)}")
          end
        else
          Mix.shell().info("Updating #{tool}...")

          case Noface.Tools.update(tool_atom) do
            :ok ->
              Mix.shell().info("#{tool} updated!")

            {:error, reason} ->
              Mix.shell().error("Failed: #{inspect(reason)}")
          end
        end
    end
  end
end

defmodule Mix.Tasks.Noface.Debug do
  @moduledoc """
  Start noface in step-wise debug mode.

  ## Usage

      mix noface.debug [--config PATH]

  This starts the server in paused mode. You can then:
  - Type 'step' or 's' to run one iteration
  - Type 'state' to inspect loop state
  - Type 'issues' to list issues
  - Type 'resume' to run continuously
  - Type 'quit' or 'q' to exit

  This is useful for understanding the orchestrator's behavior.
  """
  use Mix.Task

  @shortdoc "Start noface in step-wise debug mode"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [config: :string])
    config_path = opts[:config] || ".noface.toml"

    Mix.shell().info("Starting noface in DEBUG mode...")
    Mix.shell().info("Commands: step (s), state, issues, resume, quit (q)")
    Mix.shell().info("")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    # Load config and start in paused mode
    case Noface.Core.Config.load(config_path) do
      {:ok, config} ->
        case Noface.Core.Loop.start_paused(config) do
          :ok ->
            Mix.shell().info("Loop initialized for #{config.project_name} (paused)")
            Mix.shell().info("Type 'step' to run one iteration\n")
            debug_repl()

          {:error, reason} ->
            Mix.shell().error("Failed to start: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to load config: #{inspect(reason)}")
    end
  end

  defp debug_repl do
    case IO.gets("noface> ") do
      :eof ->
        Mix.shell().info("Exiting...")

      input ->
        input
        |> String.trim()
        |> String.downcase()
        |> handle_command()

        debug_repl()
    end
  end

  defp handle_command("step"), do: do_step()
  defp handle_command("s"), do: do_step()

  defp handle_command("state") do
    state = Noface.Core.Loop.get_loop_state()
    Mix.shell().info("""
    Loop State:
      status:     #{state.status}
      iteration:  #{state.iteration_count}
      config:     #{if state.config, do: state.config.project_name, else: "nil"}
      work:       #{inspect(state.current_work)}
    """)
  end

  defp handle_command("issues") do
    issues = Noface.Core.State.list_issues()
    Mix.shell().info("Issues (#{length(issues)}):")
    Enum.each(issues, fn issue ->
      Mix.shell().info("  #{issue.id}: #{issue.status} (attempts: #{issue.attempt_count})")
    end)
  end

  defp handle_command("batches") do
    case Noface.Core.State.get_next_pending_batch() do
      nil ->
        Mix.shell().info("No pending batches")
      batch ->
        Mix.shell().info("Next batch: #{batch.id} with #{length(batch.issue_ids)} issues")
        Mix.shell().info("  Issues: #{inspect(batch.issue_ids)}")
    end
  end

  defp handle_command("resume") do
    case Noface.Core.Loop.resume() do
      :ok -> Mix.shell().info("Loop resumed (running continuously)")
      {:error, reason} -> Mix.shell().info("Cannot resume: #{reason}")
    end
  end

  defp handle_command("pause") do
    case Noface.Core.Loop.pause() do
      :ok -> Mix.shell().info("Loop paused")
      {:error, reason} -> Mix.shell().info("Cannot pause: #{reason}")
    end
  end

  defp handle_command("quit"), do: System.halt(0)
  defp handle_command("q"), do: System.halt(0)

  defp handle_command("help") do
    Mix.shell().info("""
    Commands:
      step, s     Run one iteration
      state       Show loop state
      issues      List all issues
      batches     Show pending batches
      resume      Run continuously
      pause       Pause the loop
      quit, q     Exit
    """)
  end

  defp handle_command(""), do: :ok

  defp handle_command(cmd) do
    Mix.shell().info("Unknown command: #{cmd}. Type 'help' for commands.")
  end

  defp do_step do
    case Noface.Core.Loop.step() do
      {:ok, summary} ->
        Mix.shell().info("Stepped to iteration #{summary.iteration}")
        if summary.current_work do
          Mix.shell().info("  Work: #{inspect(summary.current_work)}")
        end

      {:error, :not_started} ->
        Mix.shell().info("Loop not started")
    end
  end
end

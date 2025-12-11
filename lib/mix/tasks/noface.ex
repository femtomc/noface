defmodule Mix.Tasks.Noface do
  @moduledoc """
  Mix tasks for interacting with a running noface server.

  ## Available commands

      mix noface.start       # Start the persistent server
      mix noface.status      # Show server status
      mix noface.pause       # Pause the loop
      mix noface.resume      # Resume the loop
      mix noface.interrupt   # Interrupt current work
      mix noface.issue       # File a new issue

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
      mix noface.start       Start the persistent server
      mix noface.status      Show server status
      mix noface.pause       Pause the loop (finish current work)
      mix noface.resume      Resume after pause
      mix noface.interrupt   Cancel current work
      mix noface.issue       File a new issue

    Run `mix help noface.<command>` for details.
    """)
  end
end

defmodule Mix.Tasks.Noface.Start do
  @moduledoc """
  Start the noface server.

  ## Usage

      mix noface.start [--config PATH]

  Options:
    --config PATH   Path to .noface.toml config file (default: .noface.toml)

  The server runs as a persistent OTP application and processes issues
  from your beads backlog. Use other `mix noface.*` commands to interact
  with the running server.
  """
  use Mix.Task

  @shortdoc "Start the noface server"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [config: :string])
    config_path = opts[:config] || ".noface.toml"

    Mix.shell().info("Starting noface server...")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    # Load config and start the loop
    case Noface.Core.Config.load(config_path) do
      {:ok, config} ->
        case Noface.Core.Loop.start(config) do
          :ok ->
            Mix.shell().info("Noface server started for #{config.project_name}")
            Mix.shell().info("Use `mix noface.status` to check status")
            # Keep running
            Process.sleep(:infinity)

          {:error, reason} ->
            Mix.shell().error("Failed to start: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to load config: #{inspect(reason)}")
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

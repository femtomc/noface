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

  defp format_duration(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  defp format_duration(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
  end
end

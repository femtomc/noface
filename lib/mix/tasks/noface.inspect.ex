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

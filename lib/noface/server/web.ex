defmodule Noface.Server.Web do
  @moduledoc """
  Web server for the noface dashboard.

  Provides HTTP and WebSocket endpoints for monitoring orchestrator status.
  """
  use Plug.Router
  require Logger

  plug(Plug.Logger)
  plug(:match)
  plug(:dispatch)

  @default_port 3000

  def start(opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)

    Logger.info("[WEB] Starting web server on port #{port}")

    children = [
      {Plug.Cowboy, scheme: :http, plug: __MODULE__, options: [port: port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Noface.Server.Web.Supervisor)
  end

  # Routes

  get "/" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{
      message: "noface API server",
      dashboard: "http://localhost:4000",
      endpoints: ["/api/status", "/api/issues", "/api/workers"]
    }))
  end

  get "/api/status" do
    status = get_orchestrator_status()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(status))
  end

  get "/api/issues" do
    case Noface.Core.State.get_state() do
      %{issues: issues} ->
        issue_list = Map.values(issues) |> Enum.map(&serialize_issue/1)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(issue_list))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, "[]")
    end
  end

  get "/api/workers" do
    case Noface.Core.State.get_state() do
      %{workers: workers, num_workers: num_workers} ->
        worker_list =
          workers
          |> Enum.take(num_workers)
          |> Enum.map(&serialize_worker/1)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(worker_list))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, "[]")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # Private functions

  defp get_orchestrator_status do
    case Noface.Core.State.get_state() do
      %{} = state ->
        %{
          project_name: state.project_name,
          total_iterations: state.total_iterations,
          successful_completions: state.successful_completions,
          failed_attempts: state.failed_attempts,
          num_workers: state.num_workers,
          pending_batches: length(state.pending_batches),
          issue_count: map_size(state.issues)
        }

      _ ->
        %{error: "State not initialized"}
    end
  end

  defp serialize_issue(issue) do
    %{
      id: issue.id,
      status: Atom.to_string(issue.status),
      attempt_count: issue.attempt_count,
      assigned_worker: issue.assigned_worker
    }
  end

  defp serialize_worker(worker) do
    %{
      id: worker.id,
      status: Atom.to_string(worker.status),
      current_issue: worker.current_issue,
      started_at: worker.started_at
    }
  end
end

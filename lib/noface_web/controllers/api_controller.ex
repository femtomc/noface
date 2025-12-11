defmodule NofaceWeb.ApiController do
  @moduledoc """
  JSON API endpoints for noface orchestrator.
  """
  use NofaceWeb, :controller

  alias Noface.Server.Command

  def status(conn, _params) do
    status = Command.status()
    json(conn, status)
  end

  def pause(conn, _params) do
    case Command.pause() do
      :ok ->
        json(conn, %{status: "ok", message: "Loop paused"})

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{status: "error", message: inspect(reason)})
    end
  end

  def resume(conn, _params) do
    case Command.resume() do
      :ok ->
        json(conn, %{status: "ok", message: "Loop resumed"})

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{status: "error", message: inspect(reason)})
    end
  end

  def interrupt(conn, _params) do
    :ok = Command.interrupt()
    json(conn, %{status: "ok", message: "Interrupted"})
  end

  def create_issue(conn, %{"title" => title} = params) do
    opts = [
      body: params["body"],
      labels: params["labels"]
    ]

    case Command.file_issue(title, opts) do
      {:ok, issue_id} ->
        conn
        |> put_status(201)
        |> json(%{status: "ok", issue_id: issue_id})

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{status: "error", message: reason})
    end
  end
end

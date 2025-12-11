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

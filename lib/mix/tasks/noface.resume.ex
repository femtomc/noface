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

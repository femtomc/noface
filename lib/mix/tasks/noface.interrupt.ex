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

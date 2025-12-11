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
      mix noface.inspect     # Inspect an issue
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
      mix noface.inspect     Inspect an issue
      mix noface.update      Update CLI tools

    Run `mix help noface.<command>` for details.
    """)
  end
end

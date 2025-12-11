defmodule Noface.Application do
  @moduledoc """
  Main application module for noface.

  Starts and supervises all the core processes:
  - Telemetry: Observability and metrics
  - State: CubDB-based persistent state management
  - Transcript: Ecto SQLite for session logging
  - Loop: Main orchestration loop
  - WorkerPool: Task.Supervisor-based parallel workers
  - Signals: Signal handling for graceful shutdown

  The supervision tree ensures fault tolerance - if any component
  crashes, it will be restarted automatically.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Attach telemetry handlers early
    Noface.Telemetry.attach_default_handlers()

    children = [
      # Core state management (CubDB-based)
      Noface.Core.State,
      # Signal handling
      Noface.Util.Signals,
      # Transcript logging (Ecto SQLite)
      {Noface.Util.Transcript.Repo, []},
      # Worker pool (Task.Supervisor-based)
      Noface.Core.WorkerPool,
      # Command server (accepts CLI commands)
      Noface.Server.Command,
      # Hot reload watcher (for self-improvement)
      Noface.HotReload,
      # Tools updater (periodic update checker)
      Noface.Tools.Updater,
      # PubSub for Phoenix
      {Phoenix.PubSub, name: Noface.PubSub},
      # Phoenix web endpoint
      NofaceWeb.Endpoint,
      # Main loop
      Noface.Core.Loop
    ]

    opts = [strategy: :one_for_one, name: Noface.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Run transcript migrations after repo starts
        run_migrations()
        Logger.info("[APP] Noface application started")
        {:ok, pid}

      error ->
        error
    end
  end

  defp run_migrations do
    Noface.Util.Transcript.migrate()
    Logger.debug("[APP] Transcript migrations complete")
  end
end

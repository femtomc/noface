defmodule Noface.HotReload do
  @moduledoc """
  Hot code reload watcher for self-improvement.

  Watches `lib/noface/` for changes and automatically recompiles and reloads
  modules when noface modifies its own code. This enables the never-ending
  loop to continuously improve itself without restarts.

  Uses FileSystem for cross-platform file watching.
  """
  use GenServer
  require Logger

  @watch_paths ["lib/noface"]
  @debounce_ms 500

  defmodule State do
    @moduledoc false
    defstruct [:watcher_pid, :pending_reload, :last_reload_at]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Manually trigger a reload."
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Get reload status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    case start_watcher() do
      {:ok, watcher_pid} ->
        Logger.info("[HOTRELOAD] Watching #{inspect(@watch_paths)} for changes")
        {:ok, %State{watcher_pid: watcher_pid, pending_reload: false, last_reload_at: nil}}

      {:error, reason} ->
        Logger.warning("[HOTRELOAD] File watching not available: #{inspect(reason)}")
        {:ok, %State{watcher_pid: nil, pending_reload: false, last_reload_at: nil}}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    result = do_reload()
    {:reply, result, %{state | last_reload_at: DateTime.utc_now()}}
  end

  def handle_call(:status, _from, state) do
    status = %{
      watching: state.watcher_pid != nil,
      watch_paths: @watch_paths,
      last_reload_at: state.last_reload_at,
      pending_reload: state.pending_reload
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    if should_reload?(path, events) do
      Logger.info("[HOTRELOAD] Detected change: #{path}")
      # Debounce: schedule reload after delay
      Process.send_after(self(), :do_reload, @debounce_ms)
      {:noreply, %{state | pending_reload: true}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("[HOTRELOAD] File watcher stopped")
    {:noreply, %{state | watcher_pid: nil}}
  end

  def handle_info(:do_reload, %{pending_reload: true} = state) do
    do_reload()
    {:noreply, %{state | pending_reload: false, last_reload_at: DateTime.utc_now()}}
  end

  def handle_info(:do_reload, state) do
    {:noreply, state}
  end

  # Private functions

  defp start_watcher do
    # Try to start FileSystem watcher
    # FileSystem is an optional dependency
    if Code.ensure_loaded?(FileSystem) do
      paths = Enum.map(@watch_paths, &Path.absname/1)
      FileSystem.start_link(dirs: paths, name: :noface_watcher)
      FileSystem.subscribe(:noface_watcher)
      {:ok, :noface_watcher}
    else
      {:error, :file_system_not_available}
    end
  rescue
    e -> {:error, e}
  end

  defp should_reload?(path, events) do
    # Only reload for Elixir source changes
    String.ends_with?(path, ".ex") and
      path =~ ~r{lib/noface/} and
      Enum.any?(events, &(&1 in [:modified, :created]))
  end

  defp do_reload do
    Logger.info("[HOTRELOAD] Recompiling and reloading modules...")

    try do
      # Recompile changed modules
      Mix.Task.reenable("compile.elixir")
      Mix.Task.run("compile.elixir", ["--force"])

      # Get all Noface modules
      noface_modules =
        :code.all_loaded()
        |> Enum.filter(fn {mod, _} ->
          mod_str = Atom.to_string(mod)
          String.starts_with?(mod_str, "Elixir.Noface.")
        end)
        |> Enum.map(fn {mod, _} -> mod end)

      # Purge and reload each module
      reloaded =
        Enum.reduce(noface_modules, [], fn mod, acc ->
          :code.purge(mod)

          case :code.load_file(mod) do
            {:module, ^mod} ->
              [mod | acc]

            {:error, reason} ->
              Logger.warning("[HOTRELOAD] Failed to reload #{mod}: #{inspect(reason)}")
              acc
          end
        end)

      Logger.info("[HOTRELOAD] Reloaded #{length(reloaded)} modules")
      :ok
    rescue
      e ->
        Logger.error("[HOTRELOAD] Reload failed: #{Exception.message(e)}")
        {:error, e}
    end
  end
end

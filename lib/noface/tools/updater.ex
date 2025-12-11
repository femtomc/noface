defmodule Noface.Tools.Updater do
  @moduledoc """
  Periodic updater for noface CLI tools.

  Checks for updates at regular intervals and optionally auto-updates.
  Emits telemetry events when updates are available or installed.
  """
  use GenServer
  require Logger

  alias Noface.Tools

  @check_interval_ms :timer.hours(6)

  defmodule State do
    @moduledoc false
    defstruct [
      :last_check,
      :available_updates,
      :auto_update,
      :check_interval_ms
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Manually trigger an update check."
  @spec check_now() :: {:ok, map()} | {:error, term()}
  def check_now do
    GenServer.call(__MODULE__, :check_now, :infinity)
  end

  @doc "Get available updates."
  @spec available_updates() :: map()
  def available_updates do
    GenServer.call(__MODULE__, :available_updates)
  end

  @doc "Update a specific tool."
  @spec update(atom()) :: :ok | {:error, term()}
  def update(tool) do
    GenServer.call(__MODULE__, {:update, tool}, :infinity)
  end

  @doc "Update all tools with available updates."
  @spec update_all() :: :ok
  def update_all do
    GenServer.call(__MODULE__, :update_all, :infinity)
  end

  @doc "Enable or disable auto-updates."
  @spec set_auto_update(boolean()) :: :ok
  def set_auto_update(enabled) do
    GenServer.call(__MODULE__, {:set_auto_update, enabled})
  end

  @doc "Get updater status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    auto_update = Keyword.get(opts, :auto_update, false)
    check_interval = Keyword.get(opts, :check_interval_ms, @check_interval_ms)

    # Schedule first check after a delay (let system stabilize)
    Process.send_after(self(), :check, :timer.minutes(5))

    {:ok,
     %State{
       last_check: nil,
       available_updates: %{},
       auto_update: auto_update,
       check_interval_ms: check_interval
     }}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    {result, new_state} = do_check(state)
    {:reply, result, new_state}
  end

  def handle_call(:available_updates, _from, state) do
    {:reply, state.available_updates, state}
  end

  def handle_call({:update, tool}, _from, state) do
    result = Tools.update(tool)

    # Re-check after update
    {_, new_state} = do_check(state)

    {:reply, result, new_state}
  end

  def handle_call(:update_all, _from, state) do
    Enum.each(state.available_updates, fn {tool, _} ->
      tool_atom = if is_binary(tool), do: String.to_atom(tool), else: tool
      Tools.update(tool_atom)
    end)

    # Re-check after updates
    {_, new_state} = do_check(state)

    {:reply, :ok, new_state}
  end

  def handle_call({:set_auto_update, enabled}, _from, state) do
    {:reply, :ok, %{state | auto_update: enabled}}
  end

  def handle_call(:status, _from, state) do
    status = %{
      last_check: state.last_check,
      available_updates: state.available_updates,
      auto_update: state.auto_update,
      installed_versions: Tools.versions()
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:check, state) do
    {_, new_state} = do_check(state)

    # Auto-update if enabled
    if new_state.auto_update and map_size(new_state.available_updates) > 0 do
      Logger.info("[UPDATER] Auto-updating tools...")

      Enum.each(new_state.available_updates, fn {tool, info} ->
        tool_atom = if is_binary(tool), do: String.to_atom(tool), else: tool
        Logger.info("[UPDATER] Updating #{tool}: #{info.current} -> #{info.latest}")
        Tools.update(tool_atom)
      end)
    end

    # Schedule next check
    Process.send_after(self(), :check, new_state.check_interval_ms)

    {:noreply, new_state}
  end

  # Private functions

  defp do_check(state) do
    Logger.debug("[UPDATER] Checking for tool updates...")

    case Tools.check_updates() do
      {:ok, updates} ->
        if map_size(updates) > 0 do
          Logger.info("[UPDATER] Updates available: #{inspect(Map.keys(updates))}")

          :telemetry.execute(
            [:noface, :tools, :updates_available],
            %{count: map_size(updates)},
            %{updates: updates}
          )
        end

        new_state = %{state | last_check: DateTime.utc_now(), available_updates: updates}
        {{:ok, updates}, new_state}

      {:error, reason} ->
        Logger.warning("[UPDATER] Failed to check updates: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end
end

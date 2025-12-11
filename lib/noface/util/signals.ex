defmodule Noface.Util.Signals do
  @moduledoc """
  Signal handling for graceful shutdown.

  Handles SIGINT (Ctrl+C) and SIGTERM for clean orchestrator shutdown.
  """
  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct interrupted: false, current_issue: nil
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Install signal handlers."
  @spec install() :: :ok
  def install do
    GenServer.call(__MODULE__, :install)
  end

  @doc "Reset interrupt flag."
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc "Check if interrupted."
  @spec interrupted?() :: boolean()
  def interrupted? do
    GenServer.call(__MODULE__, :interrupted?)
  end

  @doc "Set the current issue being worked on (for cleanup messages)."
  @spec set_current_issue(String.t() | nil) :: :ok
  def set_current_issue(issue_id) do
    GenServer.call(__MODULE__, {:set_current_issue, issue_id})
  end

  @doc "Get the current issue."
  @spec get_current_issue() :: String.t() | nil
  def get_current_issue do
    GenServer.call(__MODULE__, :get_current_issue)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call(:install, _from, state) do
    # In Elixir/Erlang, we typically handle shutdown via :init.stop/0
    # or by trapping exits. For SIGINT, the VM handles it.
    # We can use :os.set_signal/2 on supported platforms.
    try do
      :os.set_signal(:sigint, :handle)
      :os.set_signal(:sigterm, :handle)
    rescue
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | interrupted: false}}
  end

  def handle_call(:interrupted?, _from, state) do
    {:reply, state.interrupted, state}
  end

  def handle_call({:set_current_issue, issue_id}, _from, state) do
    {:reply, :ok, %{state | current_issue: issue_id}}
  end

  def handle_call(:get_current_issue, _from, state) do
    {:reply, state.current_issue, state}
  end

  @impl true
  def handle_info({:signal, :sigint}, state) do
    Logger.info("\n\e[1;33m[INTERRUPTED]\e[0m Caught signal, cleaning up...")

    if state.current_issue do
      Logger.info("\e[1;33m[INTERRUPTED]\e[0m Issue #{state.current_issue} was NOT completed")
      Logger.info("\e[1;33m[INTERRUPTED]\e[0m Issue status left as-is (check with: bd show #{state.current_issue})")
    end

    {:noreply, %{state | interrupted: true}}
  end

  def handle_info({:signal, :sigterm}, state) do
    Logger.info("\n\e[1;33m[INTERRUPTED]\e[0m Received SIGTERM, shutting down...")
    {:noreply, %{state | interrupted: true}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end

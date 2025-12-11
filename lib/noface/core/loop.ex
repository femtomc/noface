defmodule Noface.Core.Loop do
  @moduledoc """
  Main orchestration loop for the noface agent system.

  This module coordinates the entire agent execution flow:
  - Loading issues from beads
  - Running planner passes to organize batches
  - Executing batches through the worker pool
  - Running quality review passes
  - Syncing to external issue trackers

  The loop is designed to be long-running and never shuts down.
  It supports:
  - Pause/resume for inspection
  - Interrupt to cancel current work
  - Hot code reloading (state is managed externally)

  The loop runs continuously, picking up work when available.
  """
  use GenServer
  require Logger

  alias Noface.Core.{Config, State, WorkerPool, Prompts}
  alias Noface.Util.Process, as: Proc
  alias Noface.Integrations.IssueSync

  @loop_interval_ms 5_000

  defmodule LoopState do
    @moduledoc "State for the main loop."
    defstruct [
      :config,
      :status,
      :current_work,
      :iteration_count,
      :last_planner_iteration,
      :last_quality_iteration
    ]

    @type status :: :idle | :running | :paused | :interrupted

    @type t :: %__MODULE__{
            config: Config.t() | nil,
            status: status(),
            current_work: map() | nil,
            iteration_count: non_neg_integer(),
            last_planner_iteration: non_neg_integer(),
            last_quality_iteration: non_neg_integer()
          }
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start the persistent loop with the given configuration."
  @spec start(Config.t()) :: :ok | {:error, term()}
  def start(config) do
    GenServer.call(__MODULE__, {:start, config}, :infinity)
  end

  @doc "Signal the loop to stop gracefully."
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @doc "Pause the loop (finish current work, then idle)."
  @spec pause() :: :ok | {:error, :already_paused | :not_running}
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc "Resume the loop after pause."
  @spec resume() :: :ok | {:error, :not_paused}
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc "Interrupt current work immediately."
  @spec interrupt() :: :ok
  def interrupt do
    GenServer.call(__MODULE__, :interrupt)
  end

  @doc "Check if the loop is running."
  @spec running?() :: boolean()
  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  @doc "Check if the loop is paused."
  @spec paused?() :: boolean()
  def paused? do
    GenServer.call(__MODULE__, :paused?)
  end

  @doc "Get current iteration count."
  @spec current_iteration() :: non_neg_integer()
  def current_iteration do
    GenServer.call(__MODULE__, :current_iteration)
  end

  @doc "Get current work (issue being processed)."
  @spec current_work() :: map() | nil
  def current_work do
    GenServer.call(__MODULE__, :current_work)
  end

  @doc "Handle an external message (for extensibility)."
  @spec handle_external_message(term()) :: term()
  def handle_external_message(message) do
    GenServer.call(__MODULE__, {:external_message, message})
  end

  @doc """
  Run exactly one iteration, then pause.
  Useful for step-wise debugging.
  """
  @spec step() :: {:ok, map()} | {:error, :not_started}
  def step do
    GenServer.call(__MODULE__, :step, :infinity)
  end

  @doc """
  Get the full internal loop state for inspection.
  """
  @spec get_loop_state() :: LoopState.t()
  def get_loop_state do
    GenServer.call(__MODULE__, :get_loop_state)
  end

  @doc """
  Start the loop in paused mode (for step-wise debugging).
  Call step() to advance one iteration at a time.
  """
  @spec start_paused(Config.t()) :: :ok | {:error, term()}
  def start_paused(config) do
    GenServer.call(__MODULE__, {:start_paused, config}, :infinity)
  end

  @doc "Legacy: run synchronously (blocks until stopped)."
  @spec run(Config.t()) :: :ok | {:error, term()}
  def run(config) do
    GenServer.call(__MODULE__, {:run, config}, :infinity)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Schedule the first tick
    schedule_tick()

    {:ok,
     %LoopState{
       config: nil,
       status: :idle,
       current_work: nil,
       iteration_count: 0,
       last_planner_iteration: 0,
       last_quality_iteration: 0
     }}
  end

  @impl true
  def handle_call({:start, config}, _from, state) do
    Logger.info("[LOOP] Starting noface orchestrator for #{config.project_name}")

    case initialize_loop(config) do
      :ok ->
        new_state = %{state | config: config, status: :running}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Legacy run (blocking) - for backwards compatibility
  def handle_call({:run, config}, _from, state) do
    Logger.info("[LOOP] Starting noface orchestrator (blocking mode)")

    case initialize_loop(config) do
      :ok ->
        new_state = %{state | config: config, status: :running}
        result = run_blocking_loop(new_state)
        {:reply, result, %{new_state | status: :idle}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop, _from, state) do
    Logger.info("[LOOP] Stopping loop")
    {:reply, :ok, %{state | status: :idle, config: nil}}
  end

  def handle_call(:pause, _from, %{status: :running} = state) do
    Logger.info("[LOOP] Pausing loop")
    {:reply, :ok, %{state | status: :paused}}
  end

  def handle_call(:pause, _from, %{status: :paused} = state) do
    {:reply, {:error, :already_paused}, state}
  end

  def handle_call(:pause, _from, state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call(:resume, _from, %{status: :paused} = state) do
    Logger.info("[LOOP] Resuming loop")
    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call(:resume, _from, state) do
    {:reply, {:error, :not_paused}, state}
  end

  def handle_call(:interrupt, _from, state) do
    Logger.info("[LOOP] Interrupting current work")
    # Kill any active workers
    WorkerPool.interrupt_all()
    {:reply, :ok, %{state | status: :running, current_work: nil}}
  end

  def handle_call(:running?, _from, state) do
    {:reply, state.status == :running, state}
  end

  def handle_call(:paused?, _from, state) do
    {:reply, state.status == :paused, state}
  end

  def handle_call(:current_iteration, _from, state) do
    {:reply, state.iteration_count, state}
  end

  def handle_call(:current_work, _from, state) do
    {:reply, state.current_work, state}
  end

  def handle_call({:external_message, message}, _from, state) do
    Logger.debug("[LOOP] Received external message: #{inspect(message)}")
    {:reply, :ok, state}
  end

  def handle_call(:step, _from, %{config: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call(:step, _from, %{config: config} = state) when config != nil do
    Logger.info("[LOOP] Stepping one iteration")
    new_state = run_iteration(state)
    # Return to paused after step
    new_state = %{new_state | status: :paused}

    # Return a summary of what happened
    summary = %{
      iteration: new_state.iteration_count,
      current_work: new_state.current_work,
      status: new_state.status
    }

    {:reply, {:ok, summary}, new_state}
  end

  def handle_call(:get_loop_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:start_paused, config}, _from, state) do
    Logger.info("[LOOP] Starting noface orchestrator in PAUSED mode for #{config.project_name}")

    case initialize_loop(config) do
      :ok ->
        new_state = %{state | config: config, status: :paused}
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:tick, %{status: :running, config: config} = state) when config != nil do
    # Run one iteration of the loop
    new_state = run_iteration(state)
    schedule_tick()
    {:noreply, new_state}
  end

  def handle_info(:tick, state) do
    # Not running or no config - just schedule next tick
    schedule_tick()
    {:noreply, state}
  end

  def handle_info({:signal, _signum}, state) do
    Logger.info("[LOOP] Received interrupt signal")
    {:noreply, %{state | status: :paused}}
  end

  # Private: Initialize the loop
  defp initialize_loop(config) do
    case State.load(config.project_name) do
      {:ok, _orchestrator_state} ->
        case State.recover_from_crash() do
          {:ok, recovered} when recovered > 0 ->
            Logger.info("[LOOP] Recovered #{recovered} workers from crash")

          _ ->
            :ok
        end

        WorkerPool.init_pool(config)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @loop_interval_ms)
  end

  # Private functions

  # Single iteration of the loop (non-blocking, called from :tick)
  defp run_iteration(%LoopState{config: config} = state) do
    iteration = state.iteration_count + 1
    State.increment_iteration()

    Logger.debug("[LOOP] Iteration #{iteration}")

    # Check if planner pass needed
    state = maybe_run_planner(state, iteration)

    # Get next batch to execute
    case State.get_next_pending_batch() do
      nil ->
        # No batches - check if we should invoke planner (event-driven mode)
        if config.planner_mode == :event_driven and config.enable_planner do
          Logger.info("[LOOP] No ready batches, running planner (event-driven)")
          run_planner_pass(config)
        end

        %{state | iteration_count: iteration, current_work: nil}

      batch ->
        # Track current work
        state = %{state | current_work: %{type: :batch, batch: batch}}

        # Execute the batch
        case WorkerPool.execute_batch(batch) do
          {:ok, successful} ->
            Logger.info("[LOOP] Batch complete: #{successful} succeeded")

          {:error, reason} ->
            Logger.error("[LOOP] Batch execution failed: #{inspect(reason)}")
        end

        # Save state after batch
        State.save()

        # Maybe run quality pass
        state = maybe_run_quality(state, iteration)

        # Sync to external tracker if enabled
        maybe_sync_issues(config)

        %{state | iteration_count: iteration, current_work: nil}
    end
  end

  # Blocking loop for backwards compatibility
  defp run_blocking_loop(%LoopState{status: status} = state) when status != :running do
    Logger.info("[LOOP] Loop stopped")
    cleanup(state)
    :ok
  end

  defp run_blocking_loop(%LoopState{config: config} = state) do
    # Check max iterations
    if config.max_iterations > 0 and state.iteration_count >= config.max_iterations do
      Logger.info("[LOOP] Reached max iterations (#{config.max_iterations})")
      :ok
    else
      new_state = run_iteration(state)
      :timer.sleep(@loop_interval_ms)
      run_blocking_loop(new_state)
    end
  end

  defp maybe_run_planner(%LoopState{config: config} = state, iteration) do
    should_run =
      config.enable_planner and
        config.planner_mode == :interval and
        rem(iteration, config.planner_interval) == 0 and
        iteration != state.last_planner_iteration

    if should_run do
      run_planner_pass(config)
      %{state | last_planner_iteration: iteration}
    else
      state
    end
  end

  defp maybe_run_quality(%LoopState{config: config} = state, iteration) do
    should_run =
      config.enable_quality and
        rem(iteration, config.quality_interval) == 0 and
        iteration != state.last_quality_iteration

    if should_run do
      run_quality_pass(config)
      %{state | last_quality_iteration: iteration}
    else
      state
    end
  end

  defp run_planner_pass(config) do
    Logger.info("[LOOP] Running planner pass")

    directions_section =
      if config.planner_directions do
        """

        USER DIRECTIONS:
        #{config.planner_directions}
        """
      else
        ""
      end

    prompt =
      if config.monowiki_vault do
        Prompts.build_planner_prompt_with_monowiki(
          config.project_name,
          config.monowiki_vault,
          directions_section
        )
      else
        Prompts.build_planner_prompt_simple(
          config.project_name,
          directions_section
        )
      end

    run_agent_with_prompt(config.impl_agent, prompt, config)
  end

  defp run_quality_pass(config) do
    Logger.info("[LOOP] Running quality review pass")

    monowiki_section =
      if config.monowiki_vault do
        """

        DESIGN DOCUMENTS:
        Location: #{config.monowiki_vault}
        You can search for relevant design context using: monowiki search "<query>"
        """
      else
        ""
      end

    prompt = Prompts.build_quality_prompt(config.project_name, monowiki_section)

    run_agent_with_prompt(config.impl_agent, prompt, config)
  end

  defp run_agent_with_prompt(agent_cmd, prompt, config) do
    args = [
      "--print",
      prompt,
      "--output-format",
      "stream-json"
    ]

    case Proc.StreamingProcess.spawn([agent_cmd | args]) do
      {:ok, proc} ->
        stream_until_complete(proc, config.agent_timeout_seconds)
        Proc.StreamingProcess.kill(proc)
        :ok

      {:error, reason} ->
        Logger.error("[LOOP] Failed to spawn agent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stream_until_complete(proc, timeout_seconds) do
    case Proc.StreamingProcess.read_line_with_timeout(proc, timeout_seconds) do
      {{:line, line}, new_proc} ->
        # Parse and optionally display
        event = Noface.Util.Streaming.parse_stream_line(line)

        if event.text do
          IO.write(event.text)
        end

        stream_until_complete(new_proc, timeout_seconds)

      {:timeout, _} ->
        Logger.warning("Agent timed out")
        :ok

      {:eof, _} ->
        :ok
    end
  end

  defp maybe_sync_issues(config) do
    if config.sync_to_github do
      case IssueSync.sync(config.sync_provider) do
        {:ok, result} ->
          Logger.debug(
            "[LOOP] Synced issues: #{result.created} created, #{result.updated} updated"
          )

        {:error, reason} ->
          Logger.debug("[LOOP] Issue sync skipped: #{inspect(reason)}")
      end
    end
  end

  defp cleanup(state) do
    Logger.info("[LOOP] Saving final state...")
    State.save()

    if state.current_issue do
      Logger.info("[LOOP] Issue #{state.current_issue} was NOT completed")
    end
  end
end

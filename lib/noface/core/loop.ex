defmodule Noface.Core.Loop do
  @moduledoc """
  Main orchestration loop for the noface agent system.

  This module coordinates the entire agent execution flow:
  - Loading issues from beads
  - Running planner passes to organize batches
  - Executing batches through the worker pool
  - Running quality review passes
  - Syncing to external issue trackers

  The loop is designed to be long-running and supports graceful shutdown.
  Hot code reloading works because state is managed externally in GenServers.
  """
  use GenServer
  require Logger

  alias Noface.Core.{Config, State, WorkerPool, Prompts}
  alias Noface.Util.Process, as: Proc
  alias Noface.Integrations.IssueSync
  alias Noface.VCS.JJ

  @loop_interval_ms 5_000

  defmodule LoopState do
    @moduledoc "State for the main loop."
    defstruct [
      :config,
      :interrupted,
      :current_issue,
      :iteration_count,
      :last_planner_iteration,
      :last_quality_iteration
    ]

    @type t :: %__MODULE__{
            config: Config.t(),
            interrupted: boolean(),
            current_issue: String.t() | nil,
            iteration_count: non_neg_integer(),
            last_planner_iteration: non_neg_integer(),
            last_quality_iteration: non_neg_integer()
          }
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run the main loop with the given configuration."
  @spec run(Config.t()) :: :ok | {:error, term()}
  def run(config) do
    GenServer.call(__MODULE__, {:run, config}, :infinity)
  end

  @doc "Signal the loop to stop gracefully."
  @spec stop() :: :ok
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @doc "Check if the loop is running."
  @spec running?() :: boolean()
  def running? do
    GenServer.call(__MODULE__, :running?)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Set up signal handlers
    setup_signal_handlers()

    {:ok,
     %LoopState{
       config: nil,
       interrupted: false,
       current_issue: nil,
       iteration_count: 0,
       last_planner_iteration: 0,
       last_quality_iteration: 0
     }}
  end

  @impl true
  def handle_call({:run, config}, _from, state) do
    Logger.info("[LOOP] Starting noface orchestrator for #{config.project_name}")

    # Load or initialize state
    case State.load(config.project_name) do
      {:ok, _orchestrator_state} ->
        # Recover from any crashes
        case State.recover_from_crash() do
          {:ok, recovered} when recovered > 0 ->
            Logger.info("[LOOP] Recovered #{recovered} workers from crash")

          _ ->
            :ok
        end

        # Initialize worker pool
        WorkerPool.init_pool(config)

        # Run the main loop
        new_state = %{state | config: config}
        result = run_loop(new_state)

        {:reply, result, %{new_state | interrupted: false}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop, _from, state) do
    {:reply, :ok, %{state | interrupted: true}}
  end

  def handle_call(:running?, _from, state) do
    {:reply, state.config != nil and not state.interrupted, state}
  end

  @impl true
  def handle_info({:signal, _signum}, state) do
    Logger.info("[LOOP] Received interrupt signal, shutting down gracefully...")
    {:noreply, %{state | interrupted: true}}
  end

  # Private functions

  defp setup_signal_handlers do
    # In production, you'd use :os.set_signal/2 or similar
    # For now, we handle it via the stop/0 function
    :ok
  end

  defp run_loop(%LoopState{interrupted: true} = state) do
    Logger.info("[LOOP] Loop interrupted, cleaning up...")
    cleanup(state)
    :ok
  end

  defp run_loop(%LoopState{config: config} = state) do
    # Check max iterations
    if config.max_iterations > 0 and state.iteration_count >= config.max_iterations do
      Logger.info("[LOOP] Reached max iterations (#{config.max_iterations})")
      :ok
    else
      # Increment iteration
      State.increment_iteration()
      iteration = state.iteration_count + 1

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

          # Wait before checking again
          :timer.sleep(@loop_interval_ms)
          run_loop(%{state | iteration_count: iteration})

        batch ->
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

          run_loop(%{state | iteration_count: iteration})
      end
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

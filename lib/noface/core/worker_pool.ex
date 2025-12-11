defmodule Noface.Core.WorkerPool do
  @moduledoc """
  Parallel worker management using OTP Task.Supervisor.

  Leverages Elixir's built-in supervision for robust parallel execution.
  Workers are spawned as supervised tasks that can be monitored and cancelled.
  """
  use GenServer
  require Logger

  alias Noface.Core.{State, Prompts}
  alias Noface.VCS.JJ
  alias Noface.Util.Process, as: Proc
  alias Noface.Util.Streaming
  alias Noface.Tools

  @max_review_iterations 5

  defmodule WorkerResult do
    @moduledoc "Result from a worker execution."
    @type t :: %__MODULE__{
            issue_id: String.t(),
            worker_id: non_neg_integer(),
            success: boolean(),
            exit_code: integer(),
            output: String.t(),
            duration_ms: integer()
          }

    defstruct [:issue_id, :worker_id, :success, :exit_code, :output, duration_ms: 0]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Initialize the pool with configuration."
  @spec init_pool(map()) :: :ok
  def init_pool(config) do
    GenServer.call(__MODULE__, {:init_pool, config})
  end

  @doc "Execute a batch of issues in parallel using Task.async_stream."
  @spec execute_batch(map()) :: {:ok, [WorkerResult.t()]} | {:error, term()}
  def execute_batch(batch) do
    GenServer.call(__MODULE__, {:execute_batch, batch}, :infinity)
  end

  @doc "Get current worker status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Get pending results and clear them."
  @spec get_pending_results() :: [WorkerResult.t()]
  def get_pending_results do
    GenServer.call(__MODULE__, :get_pending_results)
  end

  @doc "Interrupt all active workers."
  @spec interrupt_all() :: :ok
  def interrupt_all do
    GenServer.call(__MODULE__, :interrupt_all)
  end

  @doc "Get count of available (idle) workers."
  @spec available_worker_count() :: non_neg_integer()
  def available_worker_count do
    GenServer.call(__MODULE__, :available_worker_count)
  end

  @doc """
  Dispatch a single issue to an available worker.
  Returns {:ok, task_ref} if dispatched, {:error, :no_workers} if none available.
  The task runs asynchronously - use collect_completed/0 to get results.
  """
  @spec dispatch_issue(String.t()) ::
          {:ok, reference()} | {:error, :no_workers | :not_initialized}
  def dispatch_issue(issue_id) do
    GenServer.call(__MODULE__, {:dispatch_issue, issue_id})
  end

  @doc """
  Collect completed task results without blocking.
  Returns list of completed results and removes them from the pool state.
  """
  @spec collect_completed() :: [WorkerResult.t()]
  def collect_completed do
    GenServer.call(__MODULE__, :collect_completed)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Start the Task.Supervisor for workers
    {:ok, task_sup} = Task.Supervisor.start_link(max_children: 8)

    {:ok,
     %{
       task_supervisor: task_sup,
       config: nil,
       active_tasks: %{},
       completed: []
     }}
  end

  @impl true
  def handle_call({:init_pool, config}, _from, state) do
    # Clean up any orphaned workspaces from previous runs
    case JJ.cleanup_orphaned_workspaces() do
      {:ok, cleaned} when cleaned > 0 ->
        Logger.info("[POOL] Cleaned up #{cleaned} orphaned workspaces")

      _ ->
        :ok
    end

    {:reply, :ok, %{state | config: config}}
  end

  @impl true
  def handle_call({:execute_batch, batch}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    issue_ids = batch.issue_ids

    Logger.info("[POOL] Executing batch #{batch.id} with #{length(issue_ids)} issues")

    # Emit telemetry for batch start
    :telemetry.execute(
      [:noface, :worker_pool, :batch, :start],
      %{count: length(issue_ids)},
      %{batch_id: batch.id, issue_ids: issue_ids}
    )

    # Mark batch as running
    State.update_batch_status(batch.id, :running)

    config = state.config
    max_concurrency = config.num_workers || 5
    timeout = (config.agent_timeout_seconds || 900) * 1000

    # Run all workers in parallel using Task.async_stream
    enumerable = Enum.with_index(issue_ids)

    results =
      Task.Supervisor.async_stream_nolink(
        state.task_supervisor,
        enumerable,
        fn {issue_id, idx} ->
          worker_id = rem(idx, max_concurrency)
          run_worker(issue_id, worker_id, config)
        end,
        timeout: timeout,
        max_concurrency: max_concurrency,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, :timeout} ->
          %WorkerResult{success: false, exit_code: -1, output: "Timeout"}

        {:exit, reason} ->
          %WorkerResult{success: false, exit_code: -1, output: inspect(reason)}
      end)

    duration = System.monotonic_time(:millisecond) - start_time
    successes = Enum.count(results, & &1.success)

    Logger.info(
      "[POOL] Batch #{batch.id} complete: #{successes}/#{length(results)} succeeded in #{duration}ms"
    )

    # Emit telemetry for batch completion
    :telemetry.execute(
      [:noface, :worker_pool, :batch, :stop],
      %{
        duration_ms: duration,
        success_count: successes,
        failure_count: length(results) - successes
      },
      %{batch_id: batch.id, issue_ids: issue_ids}
    )

    {:reply, {:ok, successes}, %{state | completed: results ++ state.completed}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       active_count: map_size(state.active_tasks),
       completed_count: length(state.completed),
       config: state.config
     }, state}
  end

  @impl true
  def handle_call(:get_pending_results, _from, state) do
    {:reply, state.completed, %{state | completed: []}}
  end

  @impl true
  def handle_call(:interrupt_all, _from, state) do
    # Kill all active tasks
    Enum.each(state.active_tasks, fn {_id, task} ->
      Task.Supervisor.terminate_child(state.task_supervisor, task.pid)
    end)

    Logger.info("[POOL] Interrupted all active workers")
    {:reply, :ok, %{state | active_tasks: %{}}}
  end

  @impl true
  def handle_call(:available_worker_count, _from, state) do
    config = state.config
    max_workers = if config, do: config.num_workers || 5, else: 5
    active_count = map_size(state.active_tasks)
    available = max(0, max_workers - active_count)
    {:reply, available, state}
  end

  @impl true
  def handle_call({:dispatch_issue, _issue_id}, _from, %{config: nil} = state) do
    {:reply, {:error, :not_initialized}, state}
  end

  def handle_call({:dispatch_issue, issue_id}, _from, state) do
    config = state.config
    max_workers = config.num_workers || 5
    active_count = map_size(state.active_tasks)

    if active_count >= max_workers do
      {:reply, {:error, :no_workers}, state}
    else
      # Assign worker ID based on next available slot
      worker_id = find_available_worker_id(state.active_tasks, max_workers)
      timeout = (config.agent_timeout_seconds || 900) * 1000

      # Mark issue as running and assign worker in State
      # This updates worker records so get_in_flight_issues returns correct data
      State.update_issue(issue_id, :running)
      State.assign_worker(worker_id, issue_id)

      # Emit telemetry for issue dispatch
      :telemetry.execute(
        [:noface, :worker_pool, :issue, :dispatch],
        %{},
        %{issue_id: issue_id, worker_id: worker_id}
      )

      Logger.info("[POOL] Dispatching issue #{issue_id} to worker #{worker_id}")

      # Start async task
      task =
        Task.Supervisor.async_nolink(
          state.task_supervisor,
          fn -> run_worker(issue_id, worker_id, config) end,
          timeout: timeout
        )

      new_active =
        Map.put(state.active_tasks, task.ref, %{
          task: task,
          issue_id: issue_id,
          worker_id: worker_id
        })

      {:reply, {:ok, task.ref}, %{state | active_tasks: new_active}}
    end
  end

  @impl true
  def handle_call(:collect_completed, _from, state) do
    {:reply, state.completed, %{state | completed: []}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    case Map.pop(state.active_tasks, ref) do
      {%{issue_id: issue_id, worker_id: worker_id}, new_active} ->
        Logger.info(
          "[POOL] Issue #{issue_id} completed: #{if result.success, do: "success", else: "failed"}"
        )

        # Emit telemetry
        :telemetry.execute(
          [:noface, :worker_pool, :issue, :complete],
          %{duration_ms: result.duration_ms, success: result.success},
          %{issue_id: issue_id, worker_id: result.worker_id}
        )

        # Update issue and worker status
        # Note: run_implementation_cycle may have already marked issue completed,
        # but this is idempotent and ensures consistency
        if result.success do
          State.mark_issue_completed(issue_id)
        else
          State.update_issue(issue_id, :failed)
        end

        State.complete_worker(worker_id, result.success)

        {:noreply, %{state | active_tasks: new_active, completed: [result | state.completed]}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    # Task failed or was killed
    case Map.pop(state.active_tasks, ref) do
      {%{issue_id: issue_id, worker_id: worker_id}, new_active} ->
        Logger.warning(
          "[POOL] Worker #{worker_id} crashed for issue #{issue_id}: #{inspect(reason)}"
        )

        result = %WorkerResult{
          issue_id: issue_id,
          worker_id: worker_id,
          success: false,
          exit_code: -1,
          output: "Worker crashed: #{inspect(reason)}"
        }

        State.update_issue(issue_id, :failed)
        State.complete_worker(worker_id, false)

        {:noreply, %{state | active_tasks: new_active, completed: [result | state.completed]}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  # Private functions

  defp find_available_worker_id(active_tasks, max_workers) do
    used_ids = active_tasks |> Map.values() |> Enum.map(& &1.worker_id) |> MapSet.new()
    Enum.find(0..(max_workers - 1), fn id -> not MapSet.member?(used_ids, id) end) || 0
  end

  defp run_worker(issue_id, worker_id, config) do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[WORKER-#{worker_id}] Starting work on #{issue_id}")

    # Emit telemetry
    :telemetry.execute(
      [:noface, :worker, :start],
      %{},
      %{issue_id: issue_id, worker_id: worker_id}
    )

    result =
      if config.dry_run do
        # Dry-run: skip workspace creation, just run the cycle with a fake path
        Logger.info("[WORKER-#{worker_id}] DRY-RUN: Skipping workspace creation")
        run_implementation_cycle(config, worker_id, issue_id, "/tmp/dry-run", 0, nil)
      else
        # Create workspace for this worker
        workspace_name = "noface-worker-#{worker_id}"

        case JJ.create_workspace(workspace_name) do
          {:ok, workspace_path} ->
            try do
              run_implementation_cycle(config, worker_id, issue_id, workspace_path, 0, nil)
            after
              JJ.remove_workspace(workspace_path)
            end

          {:error, reason} ->
            Logger.error("[WORKER-#{worker_id}] Failed to create workspace: #{inspect(reason)}")

            %WorkerResult{
              issue_id: issue_id,
              worker_id: worker_id,
              success: false,
              exit_code: 1,
              output: "Failed to create workspace: #{inspect(reason)}"
            }
        end
      end

    duration = System.monotonic_time(:millisecond) - start_time

    # Emit telemetry
    :telemetry.execute(
      [:noface, :worker, :stop],
      %{duration_ms: duration, success: result.success},
      %{issue_id: issue_id, worker_id: worker_id}
    )

    %{result | duration_ms: duration}
  end

  defp run_implementation_cycle(
         _config,
         worker_id,
         issue_id,
         _workspace_path,
         iteration,
         _feedback
       )
       when iteration >= @max_review_iterations do
    Logger.warning("[WORKER-#{worker_id}] Max review iterations reached for #{issue_id}")

    %WorkerResult{
      issue_id: issue_id,
      worker_id: worker_id,
      success: false,
      exit_code: 1,
      output: "Max review iterations exceeded"
    }
  end

  defp run_implementation_cycle(config, worker_id, issue_id, workspace_path, iteration, feedback) do
    Logger.info("[WORKER-#{worker_id}] Implementation iteration #{iteration + 1} for #{issue_id}")

    # Run implementation agent
    case run_agent(config.impl_agent, worker_id, issue_id, workspace_path, config, feedback) do
      {:ok, :ready_for_review} ->
        # Run review agent
        case run_reviewer(config.review_agent, worker_id, issue_id, workspace_path, config) do
          {:ok, :approved} ->
            Logger.info(
              "[WORKER-#{worker_id}] Issue #{issue_id} approved after #{iteration + 1} iterations!"
            )

            # Squash changes back to main (skip in dry-run)
            if config.dry_run do
              Logger.info("[WORKER-#{worker_id}] DRY-RUN: Skipping squash, marking complete")
              State.mark_issue_completed(issue_id)

              %WorkerResult{
                issue_id: issue_id,
                worker_id: worker_id,
                success: true,
                exit_code: 0,
                output: "DRY-RUN: Completed after #{iteration + 1} review iterations"
              }
            else
              case JJ.squash_from_workspace(workspace_path) do
                {:ok, true} ->
                  State.mark_issue_completed(issue_id)

                  %WorkerResult{
                    issue_id: issue_id,
                    worker_id: worker_id,
                    success: true,
                    exit_code: 0,
                    output: "Completed after #{iteration + 1} review iterations"
                  }

                {:ok, false} ->
                  %WorkerResult{
                    issue_id: issue_id,
                    worker_id: worker_id,
                    success: false,
                    exit_code: 1,
                    output: "Squash had conflicts"
                  }

                {:error, reason} ->
                  %WorkerResult{
                    issue_id: issue_id,
                    worker_id: worker_id,
                    success: false,
                    exit_code: 1,
                    output: "Failed to squash: #{inspect(reason)}"
                  }
              end
            end

          {:ok, {:changes_requested, new_feedback}} ->
            Logger.info("[WORKER-#{worker_id}] Changes requested for #{issue_id}")

            run_implementation_cycle(
              config,
              worker_id,
              issue_id,
              workspace_path,
              iteration + 1,
              new_feedback
            )

          {:error, reason} ->
            %WorkerResult{
              issue_id: issue_id,
              worker_id: worker_id,
              success: false,
              exit_code: 1,
              output: "Review failed: #{inspect(reason)}"
            }
        end

      {:ok, :blocked} ->
        Logger.warning("[WORKER-#{worker_id}] Issue #{issue_id} blocked")

        %WorkerResult{
          issue_id: issue_id,
          worker_id: worker_id,
          success: false,
          exit_code: 1,
          output: "Issue blocked"
        }

      {:error, reason} ->
        %WorkerResult{
          issue_id: issue_id,
          worker_id: worker_id,
          success: false,
          exit_code: 1,
          output: "Implementation failed: #{inspect(reason)}"
        }
    end
  end

  defp run_agent(agent_cmd, worker_id, issue_id, workspace_path, config, feedback) do
    # Dry-run mode: simulate agent response
    if config.dry_run do
      Logger.info("[WORKER-#{worker_id}] DRY-RUN: Simulating agent for #{issue_id}")
      # Simulate some work
      Process.sleep(500)
      {:ok, :ready_for_review}
    else
      prompt =
        Prompts.build_worker_prompt(
          issue_id,
          config.project_name,
          config.test_command,
          false,
          feedback
        )

      # Use local binary if available
      agent_bin = Tools.bin_path(String.to_atom(agent_cmd))
      Logger.debug("[WORKER-#{worker_id}] Running #{agent_bin} for #{issue_id}")

      args = build_agent_args(agent_cmd, prompt)
      env = [{"NOFACE_WORKSPACE", workspace_path}, {"NOFACE_ISSUE_ID", issue_id}]

      case Proc.StreamingProcess.spawn([agent_bin | args], env: env, cd: workspace_path) do
        {:ok, proc} ->
          result = stream_agent_output(proc, config.agent_timeout_seconds || 900)
          Proc.StreamingProcess.kill(proc)
          result

        {:error, reason} ->
          Logger.error("[WORKER-#{worker_id}] Failed to spawn agent: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp run_reviewer(review_cmd, worker_id, issue_id, workspace_path, config) do
    # Dry-run mode: simulate reviewer response
    if config.dry_run do
      Logger.info("[WORKER-#{worker_id}] DRY-RUN: Simulating reviewer for #{issue_id}")
      # Simulate some work
      Process.sleep(300)
      {:ok, :approved}
    else
      prompt =
        Prompts.build_reviewer_prompt(
          issue_id,
          config.project_name,
          config.test_command
        )

      # Use local binary if available
      review_bin = Tools.bin_path(String.to_atom(review_cmd))
      Logger.debug("[WORKER-#{worker_id}] Running reviewer #{review_bin} for #{issue_id}")

      args = build_agent_args(review_cmd, prompt)
      env = [{"NOFACE_WORKSPACE", workspace_path}, {"NOFACE_ISSUE_ID", issue_id}]

      case Proc.StreamingProcess.spawn([review_bin | args], env: env, cd: workspace_path) do
        {:ok, proc} ->
          result = stream_reviewer_output(proc, config.agent_timeout_seconds || 900)
          Proc.StreamingProcess.kill(proc)
          result

        {:error, reason} ->
          Logger.error("[WORKER-#{worker_id}] Failed to spawn reviewer: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp build_agent_args(agent_cmd, prompt) do
    case agent_cmd do
      "claude" ->
        ["--print", prompt, "--output-format", "stream-json", "--dangerously-skip-permissions"]

      "codex" ->
        ["-q", "--full-auto", prompt]

      _ ->
        ["--print", prompt, "--output-format", "stream-json"]
    end
  end

  defp stream_agent_output(proc, timeout_seconds) do
    stream_output(proc, timeout_seconds, fn line ->
      cond do
        String.contains?(line, "READY_FOR_REVIEW") -> {:halt, :ready_for_review}
        String.contains?(line, "BLOCKED:") -> {:halt, :blocked}
        true -> :continue
      end
    end)
  end

  defp stream_reviewer_output(proc, timeout_seconds) do
    stream_output(proc, timeout_seconds, fn line ->
      cond do
        String.contains?(line, "APPROVED") ->
          {:halt, :approved}

        String.contains?(line, "CHANGES_REQUESTED:") ->
          feedback = String.replace(line, ~r/.*CHANGES_REQUESTED:\s*/, "")
          {:halt, {:changes_requested, feedback}}

        true ->
          :continue
      end
    end)
  end

  defp stream_output(proc, timeout_seconds, check_fn) do
    do_stream_output(proc, timeout_seconds, check_fn, "")
  end

  defp do_stream_output(proc, timeout_seconds, check_fn, accumulated_output) do
    case Proc.StreamingProcess.read_line_with_timeout(proc, timeout_seconds) do
      {{:line, line}, new_proc} ->
        # Parse and display
        event = Streaming.parse_stream_line(line)

        if event.text do
          IO.write(event.text)
        end

        if event.tool_name do
          IO.puts("\n\e[0;36m[TOOL]\e[0m #{event.tool_name}: #{event.tool_input_summary || ""}")
        end

        # Check for termination conditions
        new_output = accumulated_output <> line <> "\n"

        case check_fn.(new_output) do
          {:halt, result} -> {:ok, result}
          :continue -> do_stream_output(new_proc, timeout_seconds, check_fn, new_output)
        end

      {:timeout, _new_proc} ->
        Logger.warning("Agent timed out after #{timeout_seconds} seconds")
        {:error, :timeout}

      {:eof, _new_proc} ->
        # Check final output
        case check_fn.(accumulated_output) do
          {:halt, result} -> {:ok, result}
          :continue -> {:error, :unexpected_eof}
        end
    end
  end
end

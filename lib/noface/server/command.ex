defmodule Noface.Server.Command do
  @moduledoc """
  Command server for interacting with a running noface instance.

  Accepts commands from CLI tools and dispatches them to the appropriate
  subsystems. Enables:
  - Querying status
  - Pausing/resuming the loop
  - Filing new issues
  - Interrupting current work
  - Inspecting issue state

  Commands are sent via `:gen_server.call` from mix tasks or other processes.
  """
  use GenServer
  require Logger

  alias Noface.Core.{Loop, State, Config}

  defmodule ServerState do
    @moduledoc false
    defstruct [:config, :started_at, :command_history]

    @type t :: %__MODULE__{
            config: Config.t() | nil,
            started_at: DateTime.t(),
            command_history: [{DateTime.t(), atom(), term()}]
          }
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current server status."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Pause the main loop (finish current work, then stop picking up new work)."
  @spec pause() :: :ok | {:error, :already_paused}
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc "Resume the main loop after pause."
  @spec resume() :: :ok | {:error, :not_paused}
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc "Interrupt current work immediately and return to idle."
  @spec interrupt() :: :ok
  def interrupt do
    GenServer.call(__MODULE__, :interrupt)
  end

  @doc "File a new issue via beads."
  @spec file_issue(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def file_issue(title, opts \\ []) do
    GenServer.call(__MODULE__, {:file_issue, title, opts})
  end

  @doc "Inspect an issue's current state."
  @spec inspect_issue(String.t()) :: {:ok, map()} | {:error, :not_found}
  def inspect_issue(issue_id) do
    GenServer.call(__MODULE__, {:inspect_issue, issue_id})
  end

  @doc "List recent issues."
  @spec list_issues(keyword()) :: {:ok, [map()]}
  def list_issues(opts \\ []) do
    GenServer.call(__MODULE__, {:list_issues, opts})
  end

  @doc "Send a message to the running loop (for custom commands)."
  @spec send_message(term()) :: term()
  def send_message(message) do
    GenServer.call(__MODULE__, {:message, message})
  end

  @doc "Get command history."
  @spec history(non_neg_integer()) :: [{DateTime.t(), atom(), term()}]
  def history(limit \\ 20) do
    GenServer.call(__MODULE__, {:history, limit})
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("[COMMAND] Command server started")

    {:ok,
     %ServerState{
       config: nil,
       started_at: DateTime.utc_now(),
       command_history: []
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      %{
        server: %{
          started_at: state.started_at,
          uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
        },
        loop: get_loop_status(),
        state: get_state_summary()
      }
      |> Map.put(:workers, get_worker_status())

    state = record_command(state, :status, nil)
    {:reply, status, state}
  end

  def handle_call(:pause, _from, state) do
    result = Loop.pause()
    state = record_command(state, :pause, result)
    {:reply, result, state}
  end

  def handle_call(:resume, _from, state) do
    result = Loop.resume()
    state = record_command(state, :resume, result)
    {:reply, result, state}
  end

  def handle_call(:interrupt, _from, state) do
    result = Loop.interrupt()
    state = record_command(state, :interrupt, result)
    {:reply, result, state}
  end

  def handle_call({:file_issue, title, opts}, _from, state) do
    result = create_issue_via_beads(title, opts)
    state = record_command(state, :file_issue, {title, result})
    {:reply, result, state}
  end

  def handle_call({:inspect_issue, issue_id}, _from, state) do
    result =
      case State.get_issue(issue_id) do
        nil -> {:error, :not_found}
        issue -> {:ok, issue}
      end

    state = record_command(state, :inspect_issue, issue_id)
    {:reply, result, state}
  end

  def handle_call({:list_issues, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 20)
    status_filter = Keyword.get(opts, :status, nil)

    issues =
      State.list_issues()
      |> maybe_filter_status(status_filter)
      |> Enum.take(limit)

    state = record_command(state, :list_issues, opts)
    {:reply, {:ok, issues}, state}
  end

  def handle_call({:message, message}, _from, state) do
    result = Loop.handle_external_message(message)
    state = record_command(state, :message, message)
    {:reply, result, state}
  end

  def handle_call({:history, limit}, _from, state) do
    history = Enum.take(state.command_history, limit)
    {:reply, history, state}
  end

  # Private helpers

  defp record_command(state, command, args) do
    entry = {DateTime.utc_now(), command, args}
    # Keep last 100 commands
    history = Enum.take([entry | state.command_history], 100)
    %{state | command_history: history}
  end

  defp get_loop_status do
    # Use short timeout since Loop may be blocked running agents
    try do
      %{
        running: GenServer.call(Loop, :running?, 500),
        paused: GenServer.call(Loop, :paused?, 500),
        iteration: GenServer.call(Loop, :current_iteration, 500),
        current_work: GenServer.call(Loop, :current_work, 500)
      }
    rescue
      _ -> %{running: false, paused: false, iteration: 0, current_work: nil}
    catch
      :exit, _ -> %{running: true, paused: false, iteration: 0, current_work: :busy}
    end
  end

  defp get_state_summary do
    try do
      # State uses :assigned and :running for in-progress issues
      assigned = State.count_issues(:assigned)
      running = State.count_issues(:running)

      %{
        total_issues: State.count_issues(),
        pending: State.count_issues(:pending),
        in_progress: assigned + running,
        completed: State.count_issues(:completed),
        failed: State.count_issues(:failed)
      }
    rescue
      _ -> %{total_issues: 0, pending: 0, in_progress: 0, completed: 0, failed: 0}
    end
  end

  defp get_worker_status do
    pool_status =
      try do
        Noface.Core.WorkerPool.status()
      rescue
        _ -> %{active_count: 0, completed_count: 0, config: nil}
      end

    state_workers =
      try do
        case State.get_state() do
          %{workers: workers, num_workers: num_workers} ->
            %{
              workers: Enum.take(workers || [], num_workers || length(workers || [])),
              num_workers: num_workers
            }

          _ ->
            nil
        end
      rescue
        _ -> nil
      end

    case state_workers do
      nil -> pool_status
      worker_map -> Map.merge(pool_status, worker_map)
    end
  end

  defp maybe_filter_status(issues, nil), do: issues

  defp maybe_filter_status(issues, status) do
    Enum.filter(issues, fn issue -> issue.status == status end)
  end

  defp create_issue_via_beads(title, opts) do
    args = ["create", title]

    args =
      if opts[:body] do
        args ++ ["--body", opts[:body]]
      else
        args
      end

    args =
      if opts[:labels] do
        args ++ ["--labels", Enum.join(opts[:labels], ",")]
      else
        args
      end

    case System.cmd("bd", args, stderr_to_stdout: true) do
      {output, 0} ->
        # Parse issue ID from output (e.g., "Created noface-abc: Title")
        case Regex.run(~r/Created ([\w-]+):/, output) do
          [_, issue_id] -> {:ok, issue_id}
          _ -> {:ok, String.trim(output)}
        end

      {error, _code} ->
        {:error, String.trim(error)}
    end
  end
end

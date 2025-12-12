defmodule Noface.Core.State do
  @moduledoc """
  Orchestrator state management using CubDB.

  Maintains persistent state across agent invocations and handles crash recovery.
  Uses CubDB for durable, embedded key-value storage with ACID transactions.

  This replaces JSON file storage with a proper embedded database that handles
  concurrent writes and provides crash recovery out of the box.
  """
  use GenServer
  require Logger

  @max_workers 8

  # DB path is computed at runtime to ensure it's relative to cwd, not compile-time dir
  defp db_path do
    Path.join(File.cwd!(), ".noface/state.cub")
  end

  # Type definitions

  @type attempt_result :: :success | :failed | :timeout | :violation
  @type issue_status :: :pending | :assigned | :running | :completed | :failed
  @type worker_status :: :idle | :starting | :running | :completed | :failed | :timeout
  @type batch_status :: :pending | :running | :completed

  defmodule Manifest do
    @moduledoc "File manifest for an issue - declares what files can be modified."
    @type t :: %__MODULE__{
            primary_files: [String.t()],
            read_files: [String.t()],
            forbidden_files: [String.t()]
          }

    defstruct primary_files: [],
              read_files: [],
              forbidden_files: []

    def allows_write?(%__MODULE__{primary_files: files}, file) do
      Enum.any?(files, fn f ->
        f == file or (String.starts_with?(f, file) and String.at(f, String.length(file)) == ":")
      end)
    end

    def forbidden?(%__MODULE__{forbidden_files: files}, file) do
      file in files
    end
  end

  defmodule AttemptRecord do
    @moduledoc "Record of an attempt on an issue."
    defstruct attempt_number: 0,
              timestamp: 0,
              result: :failed,
              files_touched: [],
              notes: ""
  end

  defmodule IssueState do
    @moduledoc "State for a single issue."
    defstruct id: "",
              content: nil,
              manifest: nil,
              assigned_worker: nil,
              attempt_count: 0,
              last_attempt: nil,
              status: :pending,
              comments: []
  end

  defmodule WorkerState do
    @moduledoc "State for a worker."
    defstruct id: 0,
              status: :idle,
              current_issue: nil,
              process_pid: nil,
              started_at: nil

    def available?(%__MODULE__{status: status}) do
      status in [:idle, :completed, :failed]
    end
  end

  defmodule Batch do
    @moduledoc "A batch of issues to execute in parallel."
    defstruct id: 0,
              issue_ids: [],
              status: :pending,
              started_at: nil,
              completed_at: nil

    def complete?(%__MODULE__{status: status}), do: status == :completed
  end

  alias Phoenix.PubSub

  # GenServer API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Load state from CubDB or create fresh"
  def load(project_name) do
    GenServer.call(__MODULE__, {:load, project_name})
  end

  @doc "Save is now a no-op since CubDB persists automatically"
  def save, do: :ok

  @doc "Get the current state as a map (for API compatibility)"
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Get a specific issue"
  def get_issue(issue_id) do
    GenServer.call(__MODULE__, {:get_issue, issue_id})
  end

  @doc "List all issues"
  def list_issues do
    GenServer.call(__MODULE__, :list_issues)
  end

  @doc "Count issues, optionally by status"
  def count_issues(status \\ nil) do
    GenServer.call(__MODULE__, {:count_issues, status})
  end

  @doc "Find an idle worker"
  def find_idle_worker do
    GenServer.call(__MODULE__, :find_idle_worker)
  end

  @doc "Assign a worker to an issue"
  def assign_worker(worker_id, issue_id) do
    GenServer.call(__MODULE__, {:assign_worker, worker_id, issue_id})
  end

  @doc "Complete a worker task"
  def complete_worker(worker_id, success?) do
    GenServer.call(__MODULE__, {:complete_worker, worker_id, success?})
  end

  @doc "Update or create issue state"
  def update_issue(issue_id, status) do
    GenServer.call(__MODULE__, {:update_issue, issue_id, status})
  end

  @doc "Mark an issue as completed"
  def mark_issue_completed(issue_id) do
    update_issue(issue_id, :completed)
  end

  @doc "Add a user comment to an issue"
  def add_comment(issue_id, author, body) do
    GenServer.call(__MODULE__, {:add_comment, issue_id, author, body})
  end

  @doc "Update issue content fields (title/description/priority/acceptance)"
  def update_issue_content(issue_id, attrs) do
    GenServer.call(__MODULE__, {:update_issue_content, issue_id, attrs})
  end

  @doc "Update batch status"
  def update_batch_status(batch_id, status) do
    GenServer.call(__MODULE__, {:update_batch_status, batch_id, status})
  end

  @doc "Record an attempt on an issue"
  def record_attempt(issue_id, result, notes) do
    GenServer.call(__MODULE__, {:record_attempt, issue_id, result, notes})
  end

  @doc "Set manifest for an issue"
  def set_manifest(issue_id, manifest) do
    GenServer.call(__MODULE__, {:set_manifest, issue_id, manifest})
  end

  @doc "Get manifest for an issue"
  def get_manifest(issue_id) do
    GenServer.call(__MODULE__, {:get_manifest, issue_id})
  end

  @doc "Add a batch of issues"
  def add_batch(issue_ids) do
    GenServer.call(__MODULE__, {:add_batch, issue_ids})
  end

  @doc "Get next pending batch"
  def get_next_pending_batch do
    GenServer.call(__MODULE__, :get_next_pending_batch)
  end

  @doc "Clear all pending batches"
  def clear_pending_batches do
    GenServer.call(__MODULE__, :clear_pending_batches)
  end

  @doc "Check if two issues conflict"
  def issues_conflict?(issue_a, issue_b) do
    GenServer.call(__MODULE__, {:issues_conflict, issue_a, issue_b})
  end

  @doc "Recover from crash"
  def recover_from_crash do
    GenServer.call(__MODULE__, :recover_from_crash)
  end

  @doc "Increment iteration counter"
  def increment_iteration do
    GenServer.call(__MODULE__, :increment_iteration)
  end

  @doc """
  Load issues from beads (.beads/issues.jsonl) into State.
  Only loads issues that aren't already in State.
  Returns {:ok, count} where count is number of new issues loaded.
  """
  @spec load_beads_issues() :: {:ok, non_neg_integer()} | {:error, term()}
  def load_beads_issues do
    GenServer.call(__MODULE__, :load_beads_issues)
  end

  @doc """
  Create a batch from pending issues (up to max_size).
  Returns {:ok, batch_id} or {:ok, nil} if no pending issues.
  """
  @spec create_batch_from_pending(non_neg_integer()) :: {:ok, non_neg_integer() | nil}
  def create_batch_from_pending(max_size \\ 5) do
    GenServer.call(__MODULE__, {:create_batch_from_pending, max_size})
  end

  @doc """
  Get the next ready issue for greedy scheduling.

  Returns the highest-priority pending issue that:
  1. Has status :pending
  2. Does not conflict with any in-flight worker's manifest
  3. Has all beads dependencies satisfied (checked via `bd ready`)

  Priority ordering: P0 > P1 > P2 (lower number = higher priority).
  Returns nil if no ready issue is available.
  """
  @spec next_ready_issue(keyword()) :: IssueState.t() | nil
  def next_ready_issue(opts \\ []) do
    GenServer.call(__MODULE__, {:next_ready_issue, opts})
  end

  @doc """
  Get all in-flight issue IDs (issues currently being worked on by workers).
  """
  @spec get_in_flight_issues() :: [String.t()]
  def get_in_flight_issues do
    GenServer.call(__MODULE__, :get_in_flight_issues)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    path = db_path()
    File.mkdir_p!(Path.dirname(path))

    case CubDB.start_link(data_dir: path, auto_compact: true) do
      {:ok, db} ->
        # Initialize workers if not present
        workers = CubDB.get(db, :workers) || init_workers()
        CubDB.put(db, :workers, workers)

        # Initialize counters
        unless CubDB.get(db, :total_iterations), do: CubDB.put(db, :total_iterations, 0)

        unless CubDB.get(db, :successful_completions),
          do: CubDB.put(db, :successful_completions, 0)

        unless CubDB.get(db, :failed_attempts), do: CubDB.put(db, :failed_attempts, 0)
        unless CubDB.get(db, :next_batch_id), do: CubDB.put(db, :next_batch_id, 1)
        unless CubDB.get(db, :num_workers), do: CubDB.put(db, :num_workers, 5)

        Logger.info("[STATE] CubDB initialized at #{path}")

        {:ok, %{db: db}}

      {:error, reason} ->
        Logger.error("[STATE] Failed to start CubDB: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:load, project_name}, _from, state) do
    CubDB.put(state.db, :project_name, project_name)

    # Emit telemetry
    issue_count = get_issue_count(state.db)

    :telemetry.execute(
      [:noface, :state, :loaded],
      %{issue_count: issue_count},
      %{project_name: project_name}
    )

    Logger.info("[STATE] Loaded state for #{project_name}: #{issue_count} issues")
    {:reply, {:ok, get_state_map(state.db)}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, get_state_map(state.db), state}
  end

  @impl true
  def handle_call({:get_issue, issue_id}, _from, state) do
    issue = CubDB.get(state.db, {:issue, issue_id})
    {:reply, issue, state}
  end

  @impl true
  def handle_call(:list_issues, _from, state) do
    issue_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()

    issues =
      issue_ids
      |> Enum.map(fn id -> CubDB.get(state.db, {:issue, id}) end)
      |> Enum.reject(&is_nil/1)

    {:reply, issues, state}
  end

  @impl true
  def handle_call({:count_issues, nil}, _from, state) do
    issue_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()
    {:reply, MapSet.size(issue_ids), state}
  end

  def handle_call({:count_issues, status}, _from, state) do
    issue_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()

    count =
      issue_ids
      |> Enum.count(fn id ->
        issue = CubDB.get(state.db, {:issue, id})
        issue && issue.status == status
      end)

    {:reply, count, state}
  end

  @impl true
  def handle_call(:find_idle_worker, _from, state) do
    workers = CubDB.get(state.db, :workers) || []
    num_workers = CubDB.get(state.db, :num_workers) || 5

    worker =
      workers
      |> Enum.take(num_workers)
      |> Enum.find(&WorkerState.available?/1)

    {:reply, worker, state}
  end

  @impl true
  def handle_call({:assign_worker, worker_id, issue_id}, _from, state) do
    workers = CubDB.get(state.db, :workers) || []

    workers =
      Enum.map(workers, fn w ->
        if w.id == worker_id do
          %{
            w
            | status: :starting,
              current_issue: issue_id,
              started_at: System.system_time(:second)
          }
        else
          w
        end
      end)

    CubDB.put(state.db, :workers, workers)
    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:complete_worker, worker_id, success?}, _from, state) do
    workers = CubDB.get(state.db, :workers) || []
    status = if success?, do: :completed, else: :failed

    workers =
      Enum.map(workers, fn w ->
        if w.id == worker_id do
          %{w | status: status, current_issue: nil}
        else
          w
        end
      end)

    CubDB.put(state.db, :workers, workers)
    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_issue, issue_id, status}, _from, state) do
    issue = CubDB.get(state.db, {:issue, issue_id}) || %IssueState{id: issue_id}
    updated = %{issue | status: status}
    CubDB.put(state.db, {:issue, issue_id}, updated)

    # Track issue ID
    issue_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()
    CubDB.put(state.db, :issue_ids, MapSet.put(issue_ids, issue_id))

    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_comment, issue_id, author, body}, _from, state) do
    issue = CubDB.get(state.db, {:issue, issue_id}) || %IssueState{id: issue_id}

    comment = %{
      author: author || "user",
      body: body,
      inserted_at: DateTime.utc_now()
    }

    comments = (issue.comments || []) ++ [comment]
    content = Map.put(issue.content || %{}, :comments, comments)
    updated = %{issue | comments: comments, content: content}

    CubDB.put(state.db, {:issue, issue_id}, updated)
    broadcast_state(state.db)
    {:reply, {:ok, updated}, state}
  end

  @impl true
  def handle_call({:update_issue_content, issue_id, attrs}, _from, state) do
    issue = CubDB.get(state.db, {:issue, issue_id}) || %IssueState{id: issue_id}
    content = Map.merge(issue.content || %{}, normalize_issue_attrs(attrs))

    updated = %{issue | content: content}
    CubDB.put(state.db, {:issue, issue_id}, updated)
    broadcast_state(state.db)
    {:reply, {:ok, updated}, state}
  end

  @impl true
  def handle_call({:update_batch_status, batch_id, status}, _from, state) do
    batch = CubDB.get(state.db, {:batch, batch_id})

    if batch do
      updated =
        case status do
          :running -> %{batch | status: :running, started_at: System.system_time(:second)}
          :completed -> %{batch | status: :completed, completed_at: System.system_time(:second)}
          _ -> %{batch | status: status}
        end

      CubDB.put(state.db, {:batch, batch_id}, updated)
    end

    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_attempt, issue_id, result, notes}, _from, state) do
    issue = CubDB.get(state.db, {:issue, issue_id}) || %IssueState{id: issue_id}
    attempt_count = issue.attempt_count + 1

    attempt = %AttemptRecord{
      attempt_number: attempt_count,
      timestamp: System.system_time(:second),
      result: result,
      notes: notes
    }

    updated = %{issue | attempt_count: attempt_count, last_attempt: attempt}
    CubDB.put(state.db, {:issue, issue_id}, updated)

    # Update counters
    case result do
      :success ->
        count = CubDB.get(state.db, :successful_completions) || 0
        CubDB.put(state.db, :successful_completions, count + 1)

      _ ->
        count = CubDB.get(state.db, :failed_attempts) || 0
        CubDB.put(state.db, :failed_attempts, count + 1)
    end

    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_manifest, issue_id, manifest}, _from, state) do
    issue = CubDB.get(state.db, {:issue, issue_id}) || %IssueState{id: issue_id}
    updated = %{issue | manifest: manifest}
    CubDB.put(state.db, {:issue, issue_id}, updated)
    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_manifest, issue_id}, _from, state) do
    issue = CubDB.get(state.db, {:issue, issue_id})
    manifest = if issue, do: issue.manifest, else: nil
    {:reply, manifest, state}
  end

  @impl true
  def handle_call({:add_batch, issue_ids}, _from, state) do
    batch_id = CubDB.get(state.db, :next_batch_id) || 1
    batch = %Batch{id: batch_id, issue_ids: issue_ids, status: :pending}

    CubDB.put(state.db, {:batch, batch_id}, batch)
    CubDB.put(state.db, :next_batch_id, batch_id + 1)

    # Track pending batch IDs
    pending = CubDB.get(state.db, :pending_batch_ids) || []
    CubDB.put(state.db, :pending_batch_ids, pending ++ [batch_id])

    Logger.info("[STATE] Added batch #{batch_id} with #{length(issue_ids)} issues")
    broadcast_state(state.db)
    {:reply, {:ok, batch_id}, state}
  end

  @impl true
  def handle_call(:get_next_pending_batch, _from, state) do
    pending_ids = CubDB.get(state.db, :pending_batch_ids) || []

    batch =
      Enum.find_value(pending_ids, fn id ->
        batch = CubDB.get(state.db, {:batch, id})
        if batch && batch.status == :pending, do: batch, else: nil
      end)

    {:reply, batch, state}
  end

  @impl true
  def handle_call(:clear_pending_batches, _from, state) do
    CubDB.put(state.db, :pending_batch_ids, [])
    Logger.info("[STATE] Cleared pending batches")
    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:issues_conflict, issue_a, issue_b}, _from, state) do
    issue_a_state = CubDB.get(state.db, {:issue, issue_a})
    issue_b_state = CubDB.get(state.db, {:issue, issue_b})

    conflicts? =
      case {issue_a_state, issue_b_state} do
        {%{manifest: %Manifest{} = a}, %{manifest: %Manifest{} = b}} ->
          Enum.any?(a.primary_files, fn file_a ->
            base_a = extract_base_file(file_a)

            Enum.any?(b.primary_files, fn file_b ->
              extract_base_file(file_b) == base_a
            end)
          end)

        _ ->
          false
      end

    {:reply, conflicts?, state}
  end

  @impl true
  def handle_call(:recover_from_crash, _from, state) do
    workers = CubDB.get(state.db, :workers) || []
    recovered = 0

    {workers, recovered} =
      Enum.map_reduce(workers, recovered, fn w, count ->
        if w.status in [:running, :starting] do
          Logger.warning("[STATE] Recovering crashed worker #{w.id}")

          if w.current_issue do
            issue = CubDB.get(state.db, {:issue, w.current_issue})

            if issue do
              CubDB.put(state.db, {:issue, w.current_issue}, %{
                issue
                | status: :pending,
                  assigned_worker: nil
              })
            end
          end

          {%{w | status: :idle, current_issue: nil, started_at: nil}, count + 1}
        else
          {w, count}
        end
      end)

    CubDB.put(state.db, :workers, workers)
    broadcast_state(state.db)
    {:reply, {:ok, recovered}, state}
  end

  @impl true
  def handle_call(:increment_iteration, _from, state) do
    count = CubDB.get(state.db, :total_iterations) || 0
    CubDB.put(state.db, :total_iterations, count + 1)
    broadcast_state(state.db)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:create_batch_from_pending, max_size}, _from, state) do
    issue_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()

    # Find pending issues
    pending_ids =
      issue_ids
      |> Enum.filter(fn id ->
        issue = CubDB.get(state.db, {:issue, id})
        issue && issue.status == :pending
      end)
      |> Enum.take(max_size)

    if pending_ids == [] do
      {:reply, {:ok, nil}, state}
    else
      # Create batch
      batch_id = CubDB.get(state.db, :next_batch_id) || 1
      batch = %Batch{id: batch_id, issue_ids: pending_ids, status: :pending}

      CubDB.put(state.db, {:batch, batch_id}, batch)
      CubDB.put(state.db, :next_batch_id, batch_id + 1)

      # Track pending batch
      pending = CubDB.get(state.db, :pending_batch_ids) || []
      CubDB.put(state.db, :pending_batch_ids, pending ++ [batch_id])

      # Mark issues as assigned
      Enum.each(pending_ids, fn id ->
        issue = CubDB.get(state.db, {:issue, id})
        if issue, do: CubDB.put(state.db, {:issue, id}, %{issue | status: :assigned})
      end)

      Logger.info("[STATE] Created batch #{batch_id} with #{length(pending_ids)} issues")
      broadcast_state(state.db)
      {:reply, {:ok, batch_id}, state}
    end
  end

  @impl true
  def handle_call(:load_beads_issues, _from, state) do
    case read_beads_issues() do
      {:ok, beads_issues} ->
        existing_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()

        # Only load issues not already in state, and only pending/in_progress ones
        new_count =
          beads_issues
          |> Enum.filter(fn issue ->
            status = issue["status"]

            status in ["open", "in_progress", nil] and
              not MapSet.member?(existing_ids, issue["id"])
          end)
          |> Enum.reduce(0, fn issue, count ->
            issue_id = issue["id"]

            issue_state = %IssueState{
              id: issue_id,
              content: issue,
              status: :pending,
              attempt_count: 0
            }

            CubDB.put(state.db, {:issue, issue_id}, issue_state)

            new_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()
            CubDB.put(state.db, :issue_ids, MapSet.put(new_ids, issue_id))

            count + 1
          end)

        Logger.info("[STATE] Loaded #{new_count} new issues from beads")
        broadcast_state(state.db)
        {:reply, {:ok, new_count}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:next_ready_issue, opts}, _from, state) do
    # Get all pending issues from state
    issue_ids = CubDB.get(state.db, :issue_ids) || MapSet.new()

    pending_issues =
      issue_ids
      |> Enum.map(fn id -> CubDB.get(state.db, {:issue, id}) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn issue -> issue.status == :pending end)

    # Get in-flight issues (issues currently being worked on)
    in_flight_ids = get_in_flight_issue_ids(state.db)

    # Get ready issue IDs from beads (respects dependencies)
    ready_ids =
      if Keyword.get(opts, :skip_beads_check, false) do
        # Skip beads check for testing - treat all pending as ready
        :all_pending
      else
        get_beads_ready_ids()
      end

    # Filter to issues that are both pending and ready in beads
    # :all_pending means all pending issues are considered ready
    ready_pending_issues =
      case ready_ids do
        :all_pending ->
          pending_issues

        %MapSet{} = ids ->
          Enum.filter(pending_issues, fn issue -> MapSet.member?(ids, issue.id) end)
      end

    # Sort by priority (lower number = higher priority)
    sorted_issues =
      ready_pending_issues
      |> Enum.sort_by(&extract_priority/1)

    # Find first issue that doesn't conflict with in-flight work
    result =
      Enum.find(sorted_issues, fn issue ->
        not conflicts_with_in_flight?(state.db, issue, in_flight_ids)
      end)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_in_flight_issues, _from, state) do
    in_flight_ids = get_in_flight_issue_ids(state.db)
    {:reply, in_flight_ids, state}
  end

  # Private functions

  defp read_beads_issues do
    issues_file = ".beads/issues.jsonl"

    case File.read(issues_file) do
      {:ok, content} ->
        issues =
          content
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, issue} -> [issue]
              {:error, _} -> []
            end
          end)

        {:ok, issues}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp init_workers do
    for i <- 0..(@max_workers - 1) do
      %WorkerState{id: i, status: :idle}
    end
  end

  defp get_issue_count(db) do
    issue_ids = CubDB.get(db, :issue_ids) || MapSet.new()
    MapSet.size(issue_ids)
  end

  defp get_state_map(db) do
    issue_ids = CubDB.get(db, :issue_ids) || MapSet.new()

    issues =
      issue_ids
      |> Enum.reduce(%{}, fn id, acc ->
        issue = CubDB.get(db, {:issue, id})
        if issue, do: Map.put(acc, id, issue), else: acc
      end)

    pending_ids = CubDB.get(db, :pending_batch_ids) || []

    pending_batches =
      pending_ids
      |> Enum.map(fn id -> CubDB.get(db, {:batch, id}) end)
      |> Enum.reject(&is_nil/1)

    %{
      project_name: CubDB.get(db, :project_name) || "unknown",
      issues: issues,
      workers: CubDB.get(db, :workers) || [],
      num_workers: CubDB.get(db, :num_workers) || 5,
      total_iterations: CubDB.get(db, :total_iterations) || 0,
      successful_completions: CubDB.get(db, :successful_completions) || 0,
      failed_attempts: CubDB.get(db, :failed_attempts) || 0,
      pending_batches: pending_batches
    }
  end

  defp broadcast_state(db) do
    snapshot = get_state_map(db)
    PubSub.broadcast(Noface.PubSub, "state", {:state, snapshot})
    :ok
  rescue
    _ -> :ok
  end

  defp extract_base_file(file_spec) do
    case String.split(file_spec, ":", parts: 2) do
      [base, _] -> base
      _ -> file_spec
    end
  end

  defp normalize_issue_attrs(attrs) do
    %{}
    |> maybe_put(:title, attrs, ["title"])
    |> maybe_put(:description, attrs, ["description"])
    |> maybe_put(:acceptance_criteria, attrs, ["acceptance_criteria", "acceptance"])
    |> maybe_put(:priority, attrs, ["priority"], &normalize_priority/1)
    |> maybe_put(:issue_type, attrs, ["issue_type"])
  end

  defp maybe_put(acc, key, attrs, candidates, transform \\ fn v -> v end) do
    # Check if any candidate key is present in attrs (even if value is empty/nil)
    {found, value} =
      Enum.reduce_while(candidates, {false, nil}, fn c, _acc ->
        str_key = c
        atom_key = String.to_atom(c)

        cond do
          Map.has_key?(attrs, str_key) -> {:halt, {true, Map.get(attrs, str_key)}}
          Map.has_key?(attrs, atom_key) -> {:halt, {true, Map.get(attrs, atom_key)}}
          true -> {:cont, {false, nil}}
        end
      end)

    # If key was present, include it (even if empty string, to allow clearing)
    if found do
      Map.put(acc, key, transform.(value))
    else
      acc
    end
  end

  defp normalize_priority(nil), do: nil
  defp normalize_priority(p) when is_integer(p), do: p

  defp normalize_priority(p) when is_binary(p) do
    case Integer.parse(p) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp normalize_priority(_), do: nil

  # Get issue IDs currently being worked on by active workers
  defp get_in_flight_issue_ids(db) do
    workers = CubDB.get(db, :workers) || []

    workers
    |> Enum.filter(fn w -> w.status in [:starting, :running] and w.current_issue != nil end)
    |> Enum.map(fn w -> w.current_issue end)
  end

  # Get ready issue IDs from beads (issues with no unsatisfied dependencies)
  defp get_beads_ready_ids do
    # Use --json format and extract IDs, with limit high enough for typical workloads
    case System.cmd("bd", ["ready", "--json", "--limit", "100"], stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, issues} when is_list(issues) ->
            issues
            |> Enum.map(fn issue -> Map.get(issue, "id") end)
            |> Enum.reject(&is_nil/1)
            |> MapSet.new()

          _ ->
            # If JSON parsing fails, treat all pending issues as ready
            # This is safe because dependency checking is a courtesy, not a hard requirement
            :all_pending
        end

      _ ->
        # If bd command fails (not installed, daemon not running, etc.),
        # treat all pending issues as ready to avoid blocking the scheduler
        Logger.debug("[STATE] bd ready command failed, treating all pending issues as ready")
        :all_pending
    end
  end

  # Extract priority from issue (lower = higher priority)
  # P0 -> 0, P1 -> 1, P2 -> 2, etc. Missing priority defaults to 99
  defp extract_priority(%IssueState{content: content}) when is_map(content) do
    priority = Map.get(content, "priority") || Map.get(content, :priority)
    normalize_priority_value(priority)
  end

  defp extract_priority(_), do: 99

  defp normalize_priority_value(nil), do: 99
  defp normalize_priority_value(p) when is_integer(p), do: p

  defp normalize_priority_value(p) when is_binary(p) do
    case Integer.parse(p) do
      {int, _} -> int
      :error -> 99
    end
  end

  defp normalize_priority_value(_), do: 99

  # Check if an issue conflicts with any in-flight issue's manifest
  defp conflicts_with_in_flight?(db, issue, in_flight_ids) do
    Enum.any?(in_flight_ids, fn in_flight_id ->
      issues_conflict_internal?(db, issue.id, in_flight_id)
    end)
  end

  # Internal conflict check (doesn't go through GenServer)
  defp issues_conflict_internal?(db, issue_a_id, issue_b_id) do
    issue_a = CubDB.get(db, {:issue, issue_a_id})
    issue_b = CubDB.get(db, {:issue, issue_b_id})

    case {issue_a, issue_b} do
      {%{manifest: %Manifest{} = a}, %{manifest: %Manifest{} = b}} ->
        Enum.any?(a.primary_files, fn file_a ->
          base_a = extract_base_file(file_a)

          Enum.any?(b.primary_files, fn file_b ->
            extract_base_file(file_b) == base_a
          end)
        end)

      _ ->
        # No conflict if either doesn't have a manifest
        false
    end
  end
end

defmodule Noface.VCS.JJ do
  @moduledoc """
  Jujutsu (jj) repository operations.

  Provides a clean interface for jj operations used by the orchestrator.
  jj is a Git-compatible VCS with better support for parallel workspaces.
  """

  alias Noface.Util.Process, as: Proc

  defmodule ChangedFiles do
    @moduledoc "Result of getting all changed files."
    @type t :: %__MODULE__{
            modified: [String.t()],
            added: [String.t()],
            deleted: [String.t()]
          }

    defstruct modified: [], added: [], deleted: []

    @doc "Get all changed files combined (without duplicates)."
    def all(%__MODULE__{modified: modified, added: added, deleted: deleted}) do
      (modified ++ added ++ deleted)
      |> Enum.uniq()
    end
  end

  @doc """
  Get list of modified files in the current working copy.
  """
  @spec get_modified_files() :: {:ok, [String.t()]} | {:error, term()}
  def get_modified_files do
    case Proc.shell("jj diff --summary 2>/dev/null") do
      {:ok, %{exit_code: 0, stdout: output}} ->
        {:ok, parse_diff_summary(output, ?M)}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get list of added files in the current working copy.
  """
  @spec get_added_files() :: {:ok, [String.t()]} | {:error, term()}
  def get_added_files do
    case Proc.shell("jj diff --summary 2>/dev/null") do
      {:ok, %{exit_code: 0, stdout: output}} ->
        {:ok, parse_diff_summary(output, ?A)}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get list of deleted files in the current working copy.
  """
  @spec get_deleted_files() :: {:ok, [String.t()]} | {:error, term()}
  def get_deleted_files do
    case Proc.shell("jj diff --summary 2>/dev/null") do
      {:ok, %{exit_code: 0, stdout: output}} ->
        {:ok, parse_diff_summary(output, ?D)}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get all changed files (modified + added + deleted).
  """
  @spec get_all_changed_files() :: {:ok, ChangedFiles.t()} | {:error, term()}
  def get_all_changed_files do
    with {:ok, modified} <- get_modified_files(),
         {:ok, added} <- get_added_files(),
         {:ok, deleted} <- get_deleted_files() do
      {:ok, %ChangedFiles{modified: modified, added: added, deleted: deleted}}
    end
  end

  @doc """
  Restore a file to its state in the parent revision.
  """
  @spec restore_file(String.t()) :: :ok | {:error, term()}
  def restore_file(file) do
    case Proc.shell(~s(jj restore "#{file}" 2>/dev/null || true)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if working directory is clean (no uncommitted changes).
  """
  @spec clean?() :: boolean()
  def clean? do
    case Proc.shell("jj diff --summary 2>/dev/null") do
      {:ok, %{exit_code: 0, stdout: output}} ->
        String.trim(output) == ""

      _ ->
        true
    end
  end

  # === Workspace Operations ===

  @doc """
  Create a new workspace for a worker.
  Returns the path to the created workspace.
  """
  @spec create_workspace(non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  def create_workspace(worker_id) do
    workspace_path = ".noface-worker-#{worker_id}"
    workspace_name = "worker-#{worker_id}"

    cmd = ~s(jj workspace add "#{workspace_path}" --name "#{workspace_name}" --revision @- 2>&1)

    case Proc.shell(cmd) do
      {:ok, %{exit_code: 0}} ->
        {:ok, workspace_path}

      {:ok, %{stdout: output}} ->
        if String.contains?(output, "already exists") do
          # Workspace exists, try to update it
          update_cmd = ~s(jj --repository "#{workspace_path}" workspace update-stale 2>&1)
          Proc.shell(update_cmd)
          {:ok, workspace_path}
        else
          {:error, {:workspace_creation_failed, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Remove a workspace.
  """
  @spec remove_workspace(String.t()) :: :ok | {:error, term()}
  def remove_workspace(workspace_path) do
    basename = Path.basename(workspace_path)

    workspace_name =
      if String.starts_with?(basename, ".noface-worker-") do
        "worker-" <> String.replace_prefix(basename, ".noface-worker-", "")
      else
        basename
      end

    # Forget the workspace from jj's tracking
    Proc.shell(~s(jj workspace forget "#{workspace_name}" 2>&1))

    # Remove the directory
    Proc.shell(~s(rm -rf "#{workspace_path}" 2>&1))

    :ok
  end

  @doc """
  List all workspaces (for cleanup/recovery).
  Returns list of workspace paths (excluding default workspace).
  """
  @spec list_workspaces() :: {:ok, [String.t()]} | {:error, term()}
  def list_workspaces do
    case Proc.shell("jj workspace list 2>/dev/null") do
      {:ok, %{exit_code: 0, stdout: output}} ->
        paths =
          output
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.starts_with?(&1, "default:"))
          |> Enum.flat_map(fn line ->
            case String.split(line, ":", parts: 2) do
              [name, _] ->
                name = String.trim(name)

                if String.starts_with?(name, "worker-") do
                  [".noface-worker-" <> String.replace_prefix(name, "worker-", "")]
                else
                  []
                end

              _ ->
                []
            end
          end)

        {:ok, paths}

      _ ->
        {:ok, []}
    end
  end

  @doc """
  Clean up orphaned noface workspaces (from crashes).
  """
  @spec cleanup_orphaned_workspaces() :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_orphaned_workspaces do
    case list_workspaces() do
      {:ok, workspaces} ->
        Enum.each(workspaces, &remove_workspace/1)
        {:ok, length(workspaces)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get changes in a workspace relative to its parent.
  """
  @spec get_workspace_changes(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def get_workspace_changes(workspace_path) do
    case Proc.shell(~s(jj --repository "#{workspace_path}" diff --summary 2>/dev/null)) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        {:ok, parse_all_changes(output)}

      _ ->
        {:ok, []}
    end
  end

  @doc """
  Commit changes in a workspace.
  """
  @spec commit_in_workspace(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def commit_in_workspace(workspace_path, message) do
    case get_workspace_changes(workspace_path) do
      {:ok, []} ->
        {:ok, false}

      {:ok, _changes} ->
        escaped_message = String.replace(message, "\"", "\\\"")
        cmd = ~s(jj --repository "#{workspace_path}" commit -m "#{escaped_message}" 2>&1)

        case Proc.shell(cmd) do
          {:ok, %{exit_code: 0}} -> {:ok, true}
          _ -> {:ok, false}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Squash workspace changes into the main working copy.
  Returns true if successful, false if there were conflicts.
  """
  @spec squash_from_workspace(String.t()) :: {:ok, boolean()} | {:error, term()}
  def squash_from_workspace(workspace_path) do
    # Get the working copy commit of the workspace
    log_cmd = ~s(jj --repository "#{workspace_path}" log -r @ --no-graph -T 'change_id' 2>/dev/null)

    case Proc.shell(log_cmd) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        change_id = String.trim(output)

        if change_id == "" do
          {:error, :workspace_commit_not_found}
        else
          squash_cmd = ~s(jj squash --from #{change_id} --into @ 2>&1)

          case Proc.shell(squash_cmd) do
            {:ok, %{exit_code: 0, stdout: squash_output}} ->
              has_conflict =
                String.contains?(squash_output, "conflict")

              {:ok, not has_conflict}

            {:ok, _} ->
              {:ok, false}

            {:error, reason} ->
              {:error, reason}
          end
        end

      _ ->
        {:error, :workspace_commit_not_found}
    end
  end

  # === Private Functions ===

  defp parse_diff_summary(output, change_type) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      trimmed = String.trim(line)

      case String.to_charlist(trimmed) do
        [^change_type, ?\s | rest] ->
          [String.trim(to_string(rest))]

        _ ->
          []
      end
    end)
  end

  defp parse_all_changes(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      trimmed = String.trim(line)

      case String.to_charlist(trimmed) do
        [type, ?\s | rest] when type in [?M, ?A, ?D] ->
          [String.trim(to_string(rest))]

        _ ->
          []
      end
    end)
  end
end

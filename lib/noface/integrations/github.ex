defmodule Noface.Integrations.GitHub do
  @moduledoc """
  GitHub integration for issue synchronization.

  Uses the `gh` CLI for GitHub operations.
  """
  @behaviour Noface.Integrations.IssueSync.Provider

  alias Noface.Util.Process, as: Proc

  @mapping_file ".beads/github-map.json"

  @doc """
  Check if prerequisites are met (gh CLI authenticated).
  """
  @spec check_prerequisites(Noface.Integrations.IssueSync.ProviderConfig.t()) :: :ok | {:error, term()}
  def check_prerequisites(_config) do
    case Proc.shell("gh auth status 2>&1") do
      {:ok, %{exit_code: 0}} ->
        :ok

      {:ok, %{stdout: output}} ->
        {:error, {:not_authenticated, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sync beads issues to GitHub.
  """
  @spec sync(Noface.Integrations.IssueSync.ProviderConfig.t(), keyword()) ::
          {:ok, Noface.Integrations.IssueSync.sync_result()} | {:error, term()}
  def sync(config, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    with :ok <- check_prerequisites(config),
         {:ok, mapping} <- load_mapping(),
         {:ok, issues} <- load_beads_issues(),
         {:ok, new_mapping, result} <- sync_issues(issues, mapping, config, dry_run),
         :ok <- save_mapping(new_mapping) do
      {:ok, result}
    end
  end

  defp load_mapping do
    case File.read(@mapping_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, mapping} -> {:ok, mapping}
          {:error, _} -> {:ok, %{}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp save_mapping(mapping) do
    File.mkdir_p!(Path.dirname(@mapping_file))

    case Jason.encode(mapping, pretty: true) do
      {:ok, json} -> File.write(@mapping_file, json)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_beads_issues do
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

  defp sync_issues(issues, mapping, _config, dry_run) do
    result = %{created: 0, updated: 0, closed: 0, skipped: 0, errors: 0}

    {new_mapping, final_result} =
      Enum.reduce(issues, {mapping, result}, fn issue, {map_acc, result_acc} ->
        issue_id = issue["id"]

        case Map.get(map_acc, issue_id) do
          nil ->
            # Create new issue on GitHub
            if dry_run do
              {map_acc, %{result_acc | skipped: result_acc.skipped + 1}}
            else
              case create_github_issue(issue) do
                {:ok, gh_number} ->
                  new_map = Map.put(map_acc, issue_id, gh_number)
                  {new_map, %{result_acc | created: result_acc.created + 1}}

                {:error, _} ->
                  {map_acc, %{result_acc | errors: result_acc.errors + 1}}
              end
            end

          _gh_number ->
            # Issue already synced - could update if changed
            {map_acc, %{result_acc | skipped: result_acc.skipped + 1}}
        end
      end)

    {:ok, new_mapping, final_result}
  end

  defp create_github_issue(issue) do
    title = issue["title"] || "Untitled Issue"
    body = issue["description"] || issue["note"] || ""

    escaped_title = String.replace(title, "\"", "\\\"")
    escaped_body = String.replace(body, "\"", "\\\"")

    cmd = ~s(gh issue create --title "#{escaped_title}" --body "#{escaped_body}" 2>&1)

    case Proc.shell(cmd) do
      {:ok, %{exit_code: 0, stdout: output}} ->
        # Parse the issue number from output (e.g., "https://github.com/owner/repo/issues/123")
        case Regex.run(~r/issues\/(\d+)/, output) do
          [_, number] -> {:ok, String.to_integer(number)}
          _ -> {:error, :parse_error}
        end

      {:ok, %{stdout: output}} ->
        {:error, {:gh_error, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

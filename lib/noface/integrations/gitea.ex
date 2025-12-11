defmodule Noface.Integrations.Gitea do
  @moduledoc """
  Gitea integration for issue synchronization.

  Uses the Gitea REST API for operations.
  """
  @behaviour Noface.Integrations.IssueSync.Provider

  alias Noface.Integrations.IssueSync.ProviderConfig

  @mapping_file ".beads/gitea-map.json"

  @doc """
  Check if prerequisites are met.
  """
  @spec check_prerequisites(ProviderConfig.t()) :: :ok | {:error, term()}
  def check_prerequisites(config) do
    cond do
      is_nil(config.api_url) ->
        {:error, :api_url_required}

      is_nil(config.repo) ->
        {:error, :repo_required}

      is_nil(config.token) and is_nil(System.get_env("GITEA_TOKEN")) ->
        {:error, :token_required}

      true ->
        :ok
    end
  end

  @doc """
  Sync beads issues to Gitea.
  """
  @spec sync(ProviderConfig.t(), keyword()) ::
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

  defp sync_issues(issues, mapping, config, dry_run) do
    result = %{created: 0, updated: 0, closed: 0, skipped: 0, errors: 0}

    {new_mapping, final_result} =
      Enum.reduce(issues, {mapping, result}, fn issue, {map_acc, result_acc} ->
        issue_id = issue["id"]

        case Map.get(map_acc, issue_id) do
          nil ->
            if dry_run do
              {map_acc, %{result_acc | skipped: result_acc.skipped + 1}}
            else
              case create_gitea_issue(issue, config) do
                {:ok, gitea_id} ->
                  new_map = Map.put(map_acc, issue_id, gitea_id)
                  {new_map, %{result_acc | created: result_acc.created + 1}}

                {:error, _} ->
                  {map_acc, %{result_acc | errors: result_acc.errors + 1}}
              end
            end

          _gitea_id ->
            {map_acc, %{result_acc | skipped: result_acc.skipped + 1}}
        end
      end)

    {:ok, new_mapping, final_result}
  end

  defp create_gitea_issue(issue, config) do
    token = config.token || System.get_env("GITEA_TOKEN")
    url = "#{config.api_url}/api/v1/repos/#{config.repo}/issues"

    body = %{
      title: issue["title"] || "Untitled Issue",
      body: issue["description"] || issue["note"] || ""
    }

    case Req.post(url,
           json: body,
           headers: [{"Authorization", "token #{token}"}]
         ) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body["id"]}

      {:ok, %{body: resp_body}} ->
        {:error, {:gitea_error, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

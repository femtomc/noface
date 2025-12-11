defmodule Noface.Core.Config do
  @moduledoc """
  Configuration for the noface agent loop.
  Supports loading from TOML files or using defaults.
  """

  @type output_format :: :text | :compact | :stream_json | :raw
  @type planner_mode :: :interval | :event_driven
  @type issue_tracker :: :beads | :github

  @type t :: %__MODULE__{
          project_name: String.t(),
          build_command: String.t(),
          test_command: String.t(),
          max_iterations: non_neg_integer(),
          specific_issue: String.t() | nil,
          dry_run: boolean(),
          enable_planner: boolean(),
          planner_interval: pos_integer(),
          planner_mode: planner_mode(),
          enable_quality: boolean(),
          quality_interval: pos_integer(),
          issue_tracker: issue_tracker(),
          sync_to_github: boolean(),
          sync_provider: Noface.Integrations.IssueSync.ProviderConfig.t(),
          impl_agent: String.t(),
          review_agent: String.t(),
          impl_prompt_template: String.t() | nil,
          planner_prompt_template: String.t() | nil,
          quality_prompt_template: String.t() | nil,
          agent_timeout_seconds: pos_integer(),
          num_workers: 1..8,
          output_format: output_format(),
          log_dir: String.t(),
          progress_file: String.t() | nil,
          monowiki_vault: String.t() | nil,
          monowiki_config: Noface.Integrations.Monowiki.Config.t() | nil,
          planner_directions: String.t() | nil,
          verbose: boolean()
        }

  defstruct project_name: "Project",
            build_command: "make build",
            test_command: "make test",
            max_iterations: 0,
            specific_issue: nil,
            dry_run: false,
            enable_planner: true,
            planner_interval: 5,
            planner_mode: :interval,
            enable_quality: true,
            quality_interval: 10,
            issue_tracker: :beads,
            sync_to_github: true,
            sync_provider: %Noface.Integrations.IssueSync.ProviderConfig{},
            impl_agent: "claude",
            review_agent: "codex",
            impl_prompt_template: nil,
            planner_prompt_template: nil,
            quality_prompt_template: nil,
            agent_timeout_seconds: 900,
            num_workers: 5,
            output_format: :compact,
            log_dir: "/tmp",
            progress_file: nil,
            monowiki_vault: nil,
            monowiki_config: nil,
            planner_directions: nil,
            verbose: false

  @doc """
  Returns the default configuration.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Load configuration from a TOML file.
  Alias for load_from_file/1.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path), do: load_from_file(path)

  @doc """
  Load configuration from a TOML file.
  """
  @spec load_from_file(String.t()) :: {:ok, t()} | {:error, term()}
  def load_from_file(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_toml(content)

      {:error, reason} ->
        {:error, {:file_error, path, reason}}
    end
  end

  @doc """
  Try to load .noface.toml from current directory, return default if not found.
  """
  @spec load_or_default() :: t()
  def load_or_default do
    case load_from_file(".noface.toml") do
      {:ok, config} -> config
      {:error, _} -> default()
    end
  end

  @doc """
  Parse TOML content into a Config struct.
  """
  @spec parse_toml(String.t()) :: {:ok, t()} | {:error, term()}
  def parse_toml(content) do
    case Toml.decode(content) do
      {:ok, toml} ->
        {:ok, build_config_from_toml(toml)}

      {:error, reason} ->
        {:error, {:toml_parse_error, reason}}
    end
  end

  defp build_config_from_toml(toml) do
    config = %__MODULE__{}

    config
    |> apply_project_section(toml["project"])
    |> apply_agents_section(toml["agents"])
    |> apply_passes_section(toml["passes"])
    |> apply_tracker_section(toml["tracker"])
    |> apply_sync_section(toml["sync"])
    |> apply_monowiki_section(toml["monowiki"])
  end

  defp apply_project_section(config, nil), do: config

  defp apply_project_section(config, section) do
    %{
      config
      | project_name: Map.get(section, "name", config.project_name),
        build_command: Map.get(section, "build", config.build_command),
        test_command: Map.get(section, "test", config.test_command)
    }
  end

  defp apply_agents_section(config, nil), do: config

  defp apply_agents_section(config, section) do
    timeout =
      case Map.get(section, "timeout_seconds") do
        nil -> config.agent_timeout_seconds
        t when is_integer(t) and t > 0 -> t
        _ -> config.agent_timeout_seconds
      end

    num_workers =
      case Map.get(section, "num_workers") do
        nil -> config.num_workers
        n when is_integer(n) and n >= 1 and n <= 8 -> n
        _ -> config.num_workers
      end

    %{
      config
      | impl_agent: Map.get(section, "implementer", config.impl_agent),
        review_agent: Map.get(section, "reviewer", config.review_agent),
        agent_timeout_seconds: timeout,
        num_workers: num_workers,
        verbose: Map.get(section, "verbose", config.verbose)
    }
  end

  defp apply_passes_section(config, nil), do: config

  defp apply_passes_section(config, section) do
    planner_enabled =
      Map.get(section, "planner_enabled") ||
        Map.get(section, "scrum_enabled", config.enable_planner)

    planner_interval =
      Map.get(section, "planner_interval") ||
        Map.get(section, "scrum_interval", config.planner_interval)

    planner_mode =
      parse_planner_mode(
        Map.get(section, "planner_mode") ||
          Map.get(section, "scrum_mode")
      ) || config.planner_mode

    %{
      config
      | enable_planner: planner_enabled,
        planner_interval: validated_interval(planner_interval, config.planner_interval),
        planner_mode: planner_mode,
        enable_quality: Map.get(section, "quality_enabled", config.enable_quality),
        quality_interval:
          validated_interval(
            Map.get(section, "quality_interval"),
            config.quality_interval
          )
    }
  end

  defp apply_tracker_section(config, nil), do: config

  defp apply_tracker_section(config, section) do
    issue_tracker =
      case Map.get(section, "type") do
        "github" -> :github
        _ -> :beads
      end

    %{
      config
      | issue_tracker: issue_tracker,
        sync_to_github: Map.get(section, "sync_to_github", config.sync_to_github)
    }
  end

  defp apply_sync_section(config, nil), do: config

  defp apply_sync_section(config, section) do
    provider_type =
      case Map.get(section, "provider") do
        "github" -> :github
        "gitea" -> :gitea
        _ -> :none
      end

    sync_provider = %Noface.Integrations.IssueSync.ProviderConfig{
      provider_type: provider_type,
      api_url: Map.get(section, "api_url"),
      repo: Map.get(section, "repo"),
      token: Map.get(section, "token")
    }

    %{config | sync_provider: sync_provider}
  end

  defp apply_monowiki_section(config, nil), do: config

  defp apply_monowiki_section(config, section) do
    vault = Map.get(section, "vault")

    if vault do
      monowiki_config = %Noface.Integrations.Monowiki.Config{
        vault: vault,
        proactive_search: Map.get(section, "proactive_search", true),
        resolve_wikilinks: Map.get(section, "resolve_wikilinks", true),
        expand_neighbors: Map.get(section, "expand_neighbors", false),
        neighbor_depth: Map.get(section, "neighbor_depth", 1),
        api_docs_slug: Map.get(section, "api_docs_slug"),
        sync_api_docs: Map.get(section, "sync_api_docs", false),
        max_context_docs: Map.get(section, "max_context_docs", 5),
        max_file_size_kb: Map.get(section, "max_file_size_kb", 100)
      }

      %{config | monowiki_vault: vault, monowiki_config: monowiki_config}
    else
      config
    end
  end

  defp parse_planner_mode("event_driven"), do: :event_driven
  defp parse_planner_mode("interval"), do: :interval
  defp parse_planner_mode(_), do: nil

  defp validated_interval(nil, default), do: default
  defp validated_interval(val, _default) when is_integer(val) and val > 0, do: val
  defp validated_interval(_, default), do: default
end

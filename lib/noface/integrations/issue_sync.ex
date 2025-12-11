defmodule Noface.Integrations.IssueSync do
  @moduledoc """
  Provider abstraction for syncing beads issues to external systems.
  """

  @type provider_type :: :github | :gitea | :none

  @type sync_result :: %{
          created: non_neg_integer(),
          updated: non_neg_integer(),
          closed: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  # Provider behaviour
  defmodule Provider do
    @moduledoc "Behaviour for issue sync providers."

    @callback sync(Noface.Integrations.IssueSync.ProviderConfig.t(), keyword()) ::
                {:ok, Noface.Integrations.IssueSync.sync_result()} | {:error, term()}

    @callback check_prerequisites(Noface.Integrations.IssueSync.ProviderConfig.t()) ::
                :ok | {:error, term()}
  end

  defmodule ProviderConfig do
    @moduledoc """
    Configuration for issue sync providers.
    """
    @type t :: %__MODULE__{
            provider_type: Noface.Integrations.IssueSync.provider_type(),
            api_url: String.t() | nil,
            repo: String.t() | nil,
            token: String.t() | nil
          }

    defstruct provider_type: :none,
              api_url: nil,
              repo: nil,
              token: nil
  end

  @doc """
  Create a provider based on configuration.
  """
  @spec create_provider(ProviderConfig.t()) ::
          {:ok, module()} | {:error, :provider_not_available}
  def create_provider(%ProviderConfig{provider_type: :github}) do
    {:ok, Noface.Integrations.GitHub}
  end

  def create_provider(%ProviderConfig{provider_type: :gitea}) do
    {:ok, Noface.Integrations.Gitea}
  end

  def create_provider(_) do
    {:error, :provider_not_available}
  end

  @doc """
  Sync issues using the configured provider.
  """
  @spec sync(ProviderConfig.t(), keyword()) :: {:ok, sync_result()} | {:error, term()}
  def sync(config, opts \\ []) do
    case create_provider(config) do
      {:ok, provider} ->
        provider.sync(config, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if prerequisites are met for syncing.
  """
  @spec check_prerequisites(ProviderConfig.t()) :: :ok | {:error, term()}
  def check_prerequisites(config) do
    case create_provider(config) do
      {:ok, provider} ->
        provider.check_prerequisites(config)

      {:error, reason} ->
        {:error, reason}
    end
  end
end

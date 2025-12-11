defmodule Noface.Util.Transcript do
  @moduledoc """
  SQLite-based transcript logging using Ecto.

  Provides permanent session logging for debugging and auditing agent runs.
  Uses Ecto with SQLite for proper schema management and querying.
  """

  use Ecto.Schema
  import Ecto.Query
  require Logger

  # Repo module
  defmodule Repo do
    use Ecto.Repo,
      otp_app: :noface_elixir,
      adapter: Ecto.Adapters.SQLite3

    def init(_type, config) do
      # Ensure .noface directory exists before starting SQLite
      File.mkdir_p!(".noface")
      config = Keyword.put(config, :database, ".noface/transcripts.db")
      {:ok, config}
    end
  end

  # Session schema
  defmodule Session do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}

    schema "sessions" do
      field :issue_id, :string
      field :worker_id, :integer
      field :resuming, :boolean, default: false
      field :exit_code, :integer
      field :completed_at, :utc_datetime

      has_many :events, Noface.Util.Transcript.Event

      timestamps(type: :utc_datetime)
    end

    def changeset(session, attrs) do
      session
      |> cast(attrs, [:issue_id, :worker_id, :resuming, :exit_code, :completed_at])
      |> validate_required([:issue_id, :worker_id])
    end
  end

  # Event schema
  defmodule Event do
    use Ecto.Schema
    import Ecto.Changeset

    schema "events" do
      field :seq, :integer
      field :event_type, :string
      field :tool_name, :string
      field :content, :string
      field :raw_json, :string

      belongs_to :session, Noface.Util.Transcript.Session, type: :binary_id

      timestamps(type: :utc_datetime)
    end

    def changeset(event, attrs) do
      event
      |> cast(attrs, [:seq, :event_type, :tool_name, :content, :raw_json, :session_id])
      |> validate_required([:seq, :event_type, :session_id])
    end
  end

  # Migration
  defmodule Migration do
    use Ecto.Migration

    def change do
      create table(:sessions, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :issue_id, :string, null: false
        add :worker_id, :integer, null: false
        add :resuming, :boolean, default: false
        add :exit_code, :integer
        add :completed_at, :utc_datetime

        timestamps(type: :utc_datetime)
      end

      create index(:sessions, [:issue_id])
      create index(:sessions, [:inserted_at])

      create table(:events) do
        add :session_id, references(:sessions, type: :binary_id, on_delete: :delete_all), null: false
        add :seq, :integer, null: false
        add :event_type, :string, null: false
        add :tool_name, :string
        add :content, :text
        add :raw_json, :text

        timestamps(type: :utc_datetime)
      end

      create index(:events, [:session_id])
      create index(:events, [:session_id, :seq])
    end
  end

  # Public API

  @doc """
  Start the transcript repository.
  """
  def start_link(opts \\ []) do
    Repo.start_link(opts)
  end

  @doc """
  Run migrations to create tables.
  """
  def migrate do
    Ecto.Migrator.run(Repo, [{0, Migration}], :up, all: true)
  end

  @doc """
  Start a new session.
  """
  @spec start_session(String.t(), non_neg_integer(), boolean()) :: {:ok, String.t()} | {:error, term()}
  def start_session(issue_id, worker_id, resuming \\ false) do
    attrs = %{
      issue_id: issue_id,
      worker_id: worker_id,
      resuming: resuming
    }

    case %Session{} |> Session.changeset(attrs) |> Repo.insert() do
      {:ok, session} ->
        Logger.debug("[TRANSCRIPT] Started session #{session.id} for #{issue_id}")
        {:ok, session.id}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Record an event in a session.
  """
  @spec record_event(String.t(), non_neg_integer(), String.t(), String.t() | nil, String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def record_event(session_id, seq, event_type, tool_name \\ nil, content \\ nil, raw_json \\ nil) do
    attrs = %{
      session_id: session_id,
      seq: seq,
      event_type: event_type,
      tool_name: tool_name,
      content: content,
      raw_json: raw_json
    }

    case %Event{} |> Event.changeset(attrs) |> Repo.insert() do
      {:ok, _event} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  End a session.
  """
  @spec end_session(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def end_session(session_id, exit_code) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Session.changeset(%{exit_code: exit_code, completed_at: DateTime.utc_now()})
        |> Repo.update()
        |> case do
          {:ok, _} ->
            Logger.debug("[TRANSCRIPT] Ended session #{session_id} with exit code #{exit_code}")
            :ok

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @doc """
  Get sessions for an issue.
  """
  @spec get_sessions(String.t()) :: {:ok, [Session.t()]} | {:error, term()}
  def get_sessions(issue_id) do
    sessions =
      Session
      |> where([s], s.issue_id == ^issue_id)
      |> order_by([s], desc: s.inserted_at)
      |> Repo.all()

    {:ok, sessions}
  end

  @doc """
  Get events for a session.
  """
  @spec get_events(String.t()) :: {:ok, [Event.t()]} | {:error, term()}
  def get_events(session_id) do
    events =
      Event
      |> where([e], e.session_id == ^session_id)
      |> order_by([e], e.seq)
      |> Repo.all()

    {:ok, events}
  end

  @doc """
  Get session with all events preloaded.
  """
  @spec get_session_with_events(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session_with_events(session_id) do
    case Repo.get(Session, session_id) |> Repo.preload(:events) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Get recent sessions across all issues.
  """
  @spec recent_sessions(non_neg_integer()) :: [Session.t()]
  def recent_sessions(limit \\ 10) do
    Session
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get session statistics.
  """
  @spec stats() :: map()
  def stats do
    total_sessions =
      Session
      |> Repo.aggregate(:count)

    successful =
      Session
      |> where([s], s.exit_code == 0)
      |> Repo.aggregate(:count)

    failed =
      Session
      |> where([s], s.exit_code != 0 and not is_nil(s.exit_code))
      |> Repo.aggregate(:count)

    in_progress =
      Session
      |> where([s], is_nil(s.exit_code))
      |> Repo.aggregate(:count)

    %{
      total: total_sessions,
      successful: successful,
      failed: failed,
      in_progress: in_progress
    }
  end

  @doc """
  Prune old sessions (older than given days).
  """
  @spec prune(non_neg_integer()) :: {:ok, non_neg_integer()}
  def prune(days \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    {deleted, _} =
      Session
      |> where([s], s.inserted_at < ^cutoff)
      |> Repo.delete_all()

    Logger.info("[TRANSCRIPT] Pruned #{deleted} sessions older than #{days} days")
    {:ok, deleted}
  end
end

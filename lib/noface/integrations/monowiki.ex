defmodule Noface.Integrations.Monowiki do
  @moduledoc """
  Integration with Monowiki design document system.
  """

  defmodule Config do
    @moduledoc """
    Configuration for Monowiki integration.
    """
    @type t :: %__MODULE__{
            vault: String.t(),
            proactive_search: boolean(),
            resolve_wikilinks: boolean(),
            expand_neighbors: boolean(),
            neighbor_depth: non_neg_integer(),
            api_docs_slug: String.t() | nil,
            sync_api_docs: boolean(),
            max_context_docs: non_neg_integer(),
            max_file_size_kb: non_neg_integer()
          }

    defstruct vault: "",
              proactive_search: true,
              resolve_wikilinks: true,
              expand_neighbors: false,
              neighbor_depth: 1,
              api_docs_slug: nil,
              sync_api_docs: false,
              max_context_docs: 5,
              max_file_size_kb: 100
  end

  defmodule SearchResult do
    @moduledoc """
    A search result from Monowiki.
    """
    @type t :: %__MODULE__{
            slug: String.t(),
            title: String.t(),
            excerpt: String.t(),
            score: float()
          }

    defstruct [:slug, :title, :excerpt, :score]
  end

  defmodule Note do
    @moduledoc """
    A note from the Monowiki vault.
    """
    @type t :: %__MODULE__{
            slug: String.t(),
            title: String.t(),
            content: String.t()
          }

    defstruct [:slug, :title, :content]
  end

  defmodule Neighbor do
    @moduledoc """
    A neighbor node in the wiki graph.
    """
    @type t :: %__MODULE__{
            slug: String.t(),
            title: String.t(),
            link_type: String.t()
          }

    defstruct [:slug, :title, :link_type]
  end

  @doc """
  Search the Monowiki vault for relevant documents.
  """
  @spec search(Config.t(), String.t(), non_neg_integer()) ::
          {:ok, [SearchResult.t()]} | {:error, term()}
  def search(config, query, limit \\ 5) do
    case System.cmd("monowiki", ["search", "--vault", config.vault, "--limit", to_string(limit), query],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, parse_search_results(output)}

      {error, _} ->
        {:error, {:monowiki_error, error}}
    end
  rescue
    e in ErlangError ->
      {:error, {:command_not_found, :monowiki, e}}
  end

  @doc """
  Fetch a note by its slug.
  """
  @spec fetch_note(Config.t(), String.t()) :: {:ok, Note.t()} | {:error, term()}
  def fetch_note(config, slug) do
    case System.cmd("monowiki", ["show", "--vault", config.vault, slug], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_note(slug, output)}

      {error, _} ->
        {:error, {:monowiki_error, error}}
    end
  rescue
    e in ErlangError ->
      {:error, {:command_not_found, :monowiki, e}}
  end

  @doc """
  Get neighbors of a note in the wiki graph.
  """
  @spec get_neighbors(Config.t(), String.t(), non_neg_integer()) ::
          {:ok, [Neighbor.t()]} | {:error, term()}
  def get_neighbors(config, slug, depth \\ 1) do
    args = ["neighbors", "--vault", config.vault, "--depth", to_string(depth), slug]

    case System.cmd("monowiki", args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_neighbors(output)}

      {error, _} ->
        {:error, {:monowiki_error, error}}
    end
  rescue
    e in ErlangError ->
      {:error, {:command_not_found, :monowiki, e}}
  end

  defp parse_search_results(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_search_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_search_line(line) do
    case Jason.decode(line) do
      {:ok, %{"slug" => slug, "title" => title, "excerpt" => excerpt, "score" => score}} ->
        %SearchResult{slug: slug, title: title, excerpt: excerpt, score: score}

      _ ->
        nil
    end
  end

  defp parse_note(slug, content) do
    # Extract title from first line if it's a markdown header
    lines = String.split(content, "\n", parts: 2)

    {title, body} =
      case lines do
        ["# " <> title | rest] -> {title, Enum.join(rest, "\n")}
        [first | rest] -> {first, Enum.join(rest, "\n")}
        [] -> {slug, ""}
      end

    %Note{slug: slug, title: String.trim(title), content: String.trim(body)}
  end

  defp parse_neighbors(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_neighbor_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_neighbor_line(line) do
    case Jason.decode(line) do
      {:ok, %{"slug" => slug, "title" => title, "link_type" => link_type}} ->
        %Neighbor{slug: slug, title: title, link_type: link_type}

      _ ->
        nil
    end
  end
end

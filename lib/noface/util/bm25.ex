defmodule Noface.Util.BM25 do
  @moduledoc """
  BM25 full-text search for code indexing.

  Implements the Okapi BM25 ranking function for searching
  code snippets and providing relevant context to agents.
  """

  @k1 1.2
  @b 0.75
  @chunk_lines 50

  defmodule Document do
    @moduledoc "A document (code chunk) in the index."
    @type t :: %__MODULE__{
            id: String.t(),
            path: String.t(),
            content: String.t(),
            start_line: non_neg_integer(),
            end_line: non_neg_integer(),
            term_count: non_neg_integer()
          }

    defstruct [:id, :path, :content, :start_line, :end_line, :term_count]
  end

  defmodule SearchResult do
    @moduledoc "A search result with score."
    @type t :: %__MODULE__{
            document: Document.t(),
            score: float()
          }

    defstruct [:document, :score]
  end

  defmodule Index do
    @moduledoc "The BM25 search index."
    @type t :: %__MODULE__{
            documents: [Document.t()],
            inverted: %{String.t() => [{non_neg_integer(), non_neg_integer()}]},
            doc_count: non_neg_integer(),
            avg_doc_len: float(),
            idf_cache: %{String.t() => float()}
          }

    defstruct documents: [],
              inverted: %{},
              doc_count: 0,
              avg_doc_len: 0.0,
              idf_cache: %{}
  end

  @doc """
  Create a new empty index.
  """
  @spec new() :: Index.t()
  def new do
    %Index{}
  end

  @doc """
  Index a directory of source files.
  """
  @spec index_directory(Index.t(), String.t(), [String.t()]) ::
          {:ok, Index.t()} | {:error, term()}
  def index_directory(
        index,
        dir,
        extensions \\ [".ex", ".exs", ".zig", ".go", ".rs", ".py", ".js", ".ts"]
      ) do
    pattern = "**/*{#{Enum.join(extensions, ",")}}"

    files =
      Path.wildcard(Path.join(dir, pattern))
      |> Enum.reject(&String.contains?(&1, "_build"))
      |> Enum.reject(&String.contains?(&1, "deps"))
      |> Enum.reject(&String.contains?(&1, "node_modules"))

    new_index =
      Enum.reduce(files, index, fn file, acc ->
        case File.read(file) do
          {:ok, content} ->
            index_file(acc, file, content)

          {:error, _} ->
            acc
        end
      end)

    {:ok, finalize_index(new_index)}
  end

  @doc """
  Index a single file by splitting it into chunks.
  """
  @spec index_file(Index.t(), String.t(), String.t()) :: Index.t()
  def index_file(index, path, content) do
    lines = String.split(content, "\n")
    chunk_count = div(length(lines) + @chunk_lines - 1, @chunk_lines)

    chunks =
      for i <- 0..(chunk_count - 1) do
        start_line = i * @chunk_lines
        end_line = min((i + 1) * @chunk_lines, length(lines))
        chunk_lines = Enum.slice(lines, start_line, end_line - start_line)
        chunk_content = Enum.join(chunk_lines, "\n")

        %Document{
          id: "#{path}:#{start_line + 1}-#{end_line}",
          path: path,
          content: chunk_content,
          start_line: start_line + 1,
          end_line: end_line,
          term_count: count_terms(chunk_content)
        }
      end

    # Add documents to index
    new_documents = index.documents ++ chunks

    # Update inverted index
    new_inverted =
      Enum.reduce(Enum.with_index(chunks, length(index.documents)), index.inverted, fn {doc,
                                                                                        doc_idx},
                                                                                       inv ->
        terms = tokenize(doc.content)
        term_freqs = Enum.frequencies(terms)

        Enum.reduce(term_freqs, inv, fn {term, freq}, inv_acc ->
          Map.update(inv_acc, term, [{doc_idx, freq}], &[{doc_idx, freq} | &1])
        end)
      end)

    %{index | documents: new_documents, inverted: new_inverted}
  end

  @doc """
  Finalize the index by computing IDF values and average document length.
  """
  @spec finalize_index(Index.t()) :: Index.t()
  def finalize_index(index) do
    doc_count = length(index.documents)

    avg_doc_len =
      if doc_count > 0 do
        Enum.sum(Enum.map(index.documents, & &1.term_count)) / doc_count
      else
        0.0
      end

    # Compute IDF for each term
    idf_cache =
      Enum.reduce(index.inverted, %{}, fn {term, postings}, cache ->
        df = length(postings)
        idf = :math.log((doc_count - df + 0.5) / (df + 0.5) + 1)
        Map.put(cache, term, idf)
      end)

    %{index | doc_count: doc_count, avg_doc_len: avg_doc_len, idf_cache: idf_cache}
  end

  @doc """
  Search the index for documents matching the query.
  """
  @spec search(Index.t(), String.t(), non_neg_integer()) :: [SearchResult.t()]
  def search(index, query, max_results \\ 10) do
    if index.doc_count == 0 do
      []
    else
      query_terms = tokenize(query)

      # Score each document
      scores =
        Enum.map(0..(index.doc_count - 1), fn doc_idx ->
          doc = Enum.at(index.documents, doc_idx)
          score = score_document(index, doc_idx, doc, query_terms)
          {doc_idx, score}
        end)

      # Sort by score and take top results
      scores
      |> Enum.filter(fn {_, score} -> score > 0 end)
      |> Enum.sort_by(fn {_, score} -> -score end)
      |> Enum.take(max_results)
      |> Enum.map(fn {doc_idx, score} ->
        %SearchResult{
          document: Enum.at(index.documents, doc_idx),
          score: score
        }
      end)
    end
  end

  defp score_document(index, doc_idx, doc, query_terms) do
    doc_len = doc.term_count

    Enum.reduce(query_terms, 0.0, fn term, total_score ->
      case Map.get(index.idf_cache, term) do
        nil ->
          total_score

        idf ->
          # Get term frequency in this document
          tf =
            case Map.get(index.inverted, term) do
              nil ->
                0

              postings ->
                case Enum.find(postings, fn {idx, _} -> idx == doc_idx end) do
                  nil -> 0
                  {_, freq} -> freq
                end
            end

          if tf > 0 do
            # BM25 formula
            numerator = tf * (@k1 + 1)
            denominator = tf + @k1 * (1 - @b + @b * doc_len / index.avg_doc_len)
            total_score + idf * (numerator / denominator)
          else
            total_score
          end
      end
    end)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
  end

  defp count_terms(text) do
    length(tokenize(text))
  end
end

defmodule Noface.Util.Streaming do
  @moduledoc """
  Streaming JSON parser for Claude's stream-json output format.

  Uses Jaxon for proper streaming JSON parsing that handles incomplete
  chunks and provides event-based parsing for large responses.
  """

  @type event_type :: :system | :assistant | :user | :stream_event | :result | :unknown

  @type stream_event :: %{
          event_type: event_type(),
          text: String.t() | nil,
          tool_name: String.t() | nil,
          tool_input_summary: String.t() | nil,
          result: String.t() | nil,
          is_error: boolean()
        }

  defmodule StreamParser do
    @moduledoc """
    Stateful streaming parser using Jaxon.

    Handles incomplete JSON chunks and emits events as they become complete.
    """

    defstruct buffer: "", events: []

    @type t :: %__MODULE__{
            buffer: String.t(),
            events: [Noface.Util.Streaming.stream_event()]
          }

    @doc "Create a new parser state"
    def new, do: %__MODULE__{}

    @doc "Feed data into the parser, returns {events, new_state}"
    @spec feed(t(), String.t()) :: {[Noface.Util.Streaming.stream_event()], t()}
    def feed(%__MODULE__{buffer: buffer} = state, data) do
      full_buffer = buffer <> data

      # Split on newlines and try to parse each complete line
      {events, remaining} = parse_lines(full_buffer)

      {events, %{state | buffer: remaining, events: []}}
    end

    defp parse_lines(data) do
      lines = String.split(data, "\n")

      # The last element might be incomplete
      {complete_lines, incomplete} =
        case lines do
          [] -> {[], ""}
          [single] -> {[], single}
          many -> {Enum.drop(many, -1), List.last(many)}
        end

      events =
        complete_lines
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Noface.Util.Streaming.parse_stream_line/1)

      {events, incomplete}
    end
  end

  @doc """
  Create a new streaming parser.
  """
  @spec new_parser() :: StreamParser.t()
  def new_parser, do: StreamParser.new()

  @doc """
  Feed data into the parser, returns parsed events and new parser state.
  """
  @spec feed_parser(StreamParser.t(), String.t()) :: {[stream_event()], StreamParser.t()}
  def feed_parser(parser, data), do: StreamParser.feed(parser, data)

  @doc """
  Parse a single JSON line from Claude's streaming output.
  """
  @spec parse_stream_line(String.t()) :: stream_event()
  def parse_stream_line(line) do
    # Try Jaxon first for potentially large JSON
    case parse_with_jaxon(line) do
      {:ok, json} -> parse_json_event(json)
      :error -> parse_with_jason(line)
    end
  end

  defp parse_with_jaxon(line) do
    try do
      # Jaxon.decode! for complete JSON objects
      json = Jaxon.decode!(line)
      {:ok, json}
    rescue
      _ -> :error
    end
  end

  defp parse_with_jason(line) do
    case Jason.decode(line) do
      {:ok, json} ->
        parse_json_event(json)

      {:error, _} ->
        %{
          event_type: :unknown,
          text: nil,
          tool_name: nil,
          tool_input_summary: nil,
          result: nil,
          is_error: false
        }
    end
  end

  @doc """
  Parse a stream of data using Jaxon's streaming capabilities.

  This is useful for parsing very large JSON responses incrementally.
  """
  @spec stream_parse(Enumerable.t()) :: Enumerable.t()
  def stream_parse(data_stream) do
    data_stream
    |> Stream.flat_map(fn chunk ->
      chunk
      |> String.split("\n", trim: true)
      |> Enum.map(&parse_stream_line/1)
    end)
  end

  defp parse_json_event(%{"type" => type_str} = json) do
    event_type = parse_event_type(type_str)

    base_event = %{
      event_type: event_type,
      text: nil,
      tool_name: nil,
      tool_input_summary: nil,
      result: nil,
      is_error: false
    }

    base_event
    |> maybe_parse_stream_event(event_type, json)
    |> maybe_parse_assistant(event_type, json)
    |> maybe_parse_result(event_type, json)
  end

  defp parse_json_event(_) do
    %{
      event_type: :unknown,
      text: nil,
      tool_name: nil,
      tool_input_summary: nil,
      result: nil,
      is_error: false
    }
  end

  defp parse_event_type("stream_event"), do: :stream_event
  defp parse_event_type("assistant"), do: :assistant
  defp parse_event_type("user"), do: :user
  defp parse_event_type("system"), do: :system
  defp parse_event_type("result"), do: :result
  defp parse_event_type(_), do: :unknown

  defp maybe_parse_stream_event(event, :stream_event, json) do
    text =
      get_in(json, ["event", "delta", "text"]) ||
        get_in(json, ["event", "delta", "partial_json"])

    %{event | text: text}
  end

  defp maybe_parse_stream_event(event, _, _), do: event

  defp maybe_parse_assistant(event, :assistant, json) do
    case get_in(json, ["message", "content"]) do
      [%{"type" => "tool_use", "name" => name} = tool_content | _] ->
        summary = extract_tool_summary(name, Map.get(tool_content, "input", %{}))
        %{event | tool_name: name, tool_input_summary: summary}

      _ ->
        event
    end
  end

  defp maybe_parse_assistant(event, _, _), do: event

  defp maybe_parse_result(event, :result, json) do
    %{
      event
      | result: json["result"],
        is_error: Map.get(json, "is_error", false)
    }
  end

  defp maybe_parse_result(event, _, _), do: event

  @doc """
  Extract a human-readable summary from tool input based on tool type.
  """
  @spec extract_tool_summary(String.t(), map()) :: String.t() | nil
  def extract_tool_summary(tool_name, input) when tool_name in ["Read", "Edit", "Write"] do
    Map.get(input, "file_path")
  end

  def extract_tool_summary("Bash", input) do
    case Map.get(input, "command") do
      nil ->
        nil

      cmd when byte_size(cmd) <= 60 ->
        cmd

      cmd ->
        String.slice(cmd, 0, 60) <> "..."
    end
  end

  def extract_tool_summary("Glob", input), do: Map.get(input, "pattern")
  def extract_tool_summary("Grep", input), do: Map.get(input, "pattern")
  def extract_tool_summary("Task", input), do: Map.get(input, "description")
  def extract_tool_summary(_, _), do: nil

  @doc """
  Print text delta to stdout (for streaming display).
  """
  @spec print_text_delta(stream_event()) :: :ok
  def print_text_delta(%{text: text}) when is_binary(text) do
    IO.write(text)
    :ok
  end

  def print_text_delta(%{tool_name: name, tool_input_summary: summary})
      when is_binary(name) do
    if summary do
      IO.puts("\n\e[0;36m[TOOL]\e[0m #{name}: #{summary}")
    else
      IO.puts("\n\e[0;36m[TOOL]\e[0m #{name}")
    end

    :ok
  end

  def print_text_delta(_), do: :ok

  @doc """
  Collect all text from a stream of events.
  """
  @spec collect_text([stream_event()]) :: String.t()
  def collect_text(events) do
    events
    |> Enum.map(& &1.text)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("")
  end

  @doc """
  Collect all tool uses from a stream of events.
  """
  @spec collect_tools([stream_event()]) :: [{String.t(), String.t() | nil}]
  def collect_tools(events) do
    events
    |> Enum.filter(& &1.tool_name)
    |> Enum.map(&{&1.tool_name, &1.tool_input_summary})
  end
end

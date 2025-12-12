defmodule Noface.Integrations.LSP do
  @moduledoc """
  LSP client for semantic code analysis.

  Communicates with language servers (zls, rust-analyzer, elixir-ls, etc.)
  to provide agents with semantic understanding: definitions, references, call graphs.

  ## Features

  - Spawn LSP subprocess and communicate via JSON-RPC over stdio
  - Expose semantic tools: goto_definition, find_references, list_symbols
  - Build and cache code graph for call hierarchy queries
  - Graceful fallback when LSP unavailable

  ## Usage

      # Start and connect to a language server
      {:ok, _pid} = Noface.Integrations.LSP.start_link()
      :ok = Noface.Integrations.LSP.connect("rust-analyzer", "/path/to/project")

      # Use semantic navigation
      {:ok, location} = Noface.Integrations.LSP.goto_definition("src/main.rs", 10, 5)
      {:ok, refs} = Noface.Integrations.LSP.find_references("src/main.rs", 10, 5)

      # Use call graph
      {:ok, callers} = Noface.Integrations.LSP.get_callers("src/main.rs", 20, 10)
      {:ok, callees} = Noface.Integrations.LSP.get_callees("src/main.rs", 20, 10)

  """
  use GenServer
  require Logger

  @default_timeout 10_000
  @init_timeout 30_000

  defmodule Location do
    @moduledoc "A location in source code."
    @type t :: %__MODULE__{
            uri: String.t(),
            line: non_neg_integer(),
            character: non_neg_integer(),
            end_line: non_neg_integer(),
            end_character: non_neg_integer()
          }

    defstruct [:uri, :line, :character, :end_line, :end_character]

    @doc "Extract file path from URI."
    @spec path(t()) :: String.t()
    def path(%__MODULE__{uri: uri}) do
      case uri do
        "file://" <> path -> URI.decode(path)
        other -> other
      end
    end

    @doc "Format location as file:line:col."
    @spec format(t()) :: String.t()
    def format(%__MODULE__{} = loc) do
      "#{path(loc)}:#{loc.line + 1}:#{loc.character + 1}"
    end
  end

  defmodule Symbol do
    @moduledoc "A symbol in a document."
    @type t :: %__MODULE__{
            name: String.t(),
            kind: atom(),
            location: Location.t(),
            container: String.t() | nil
          }

    defstruct [:name, :kind, :location, :container]
  end

  defmodule CallHierarchyItem do
    @moduledoc "An item in a call hierarchy."
    @type t :: %__MODULE__{
            name: String.t(),
            kind: atom(),
            uri: String.t(),
            range: map(),
            selection_range: map(),
            data: term()
          }

    defstruct [:name, :kind, :uri, :range, :selection_range, :data]
  end

  @symbol_kinds %{
    1 => :file,
    2 => :module,
    3 => :namespace,
    4 => :package,
    5 => :class,
    6 => :method,
    7 => :property,
    8 => :field,
    9 => :constructor,
    10 => :enum,
    11 => :interface,
    12 => :function,
    13 => :variable,
    14 => :constant,
    15 => :string,
    16 => :number,
    17 => :boolean,
    18 => :array,
    19 => :object,
    20 => :key,
    21 => :null,
    22 => :enum_member,
    23 => :struct,
    24 => :event,
    25 => :operator,
    26 => :type_parameter
  }

  # Client API

  @doc """
  Start the LSP client GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Connect to an LSP server.

  ## Parameters

  - `server_cmd` - The LSP server executable (e.g., "rust-analyzer", "zls")
  - `root_path` - The project root directory

  ## Returns

  - `:ok` on successful connection
  - `{:error, reason}` if connection fails
  """
  @spec connect(String.t(), String.t()) :: :ok | {:error, term()}
  def connect(server_cmd, root_path) do
    GenServer.call(__MODULE__, {:connect, server_cmd, root_path}, @init_timeout)
  end

  @doc "Disconnect from LSP server."
  @spec disconnect() :: :ok
  def disconnect do
    GenServer.call(__MODULE__, :disconnect)
  end

  @doc "Check if connected to an LSP server."
  @spec connected?() :: boolean()
  def connected? do
    GenServer.call(__MODULE__, :connected?)
  end

  @doc "Go to definition of symbol at position."
  @spec goto_definition(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Location.t() | nil} | {:error, term()}
  def goto_definition(file_path, line, col) do
    GenServer.call(__MODULE__, {:goto_definition, file_path, line, col}, @default_timeout)
  end

  @doc "Find all references to symbol at position."
  @spec find_references(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [Location.t()]} | {:error, term()}
  def find_references(file_path, line, col) do
    GenServer.call(__MODULE__, {:find_references, file_path, line, col}, @default_timeout)
  end

  @doc "Get hover information (type, docs)."
  @spec hover(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def hover(file_path, line, col) do
    GenServer.call(__MODULE__, {:hover, file_path, line, col}, @default_timeout)
  end

  @doc "Get document symbols (functions, structs, etc.)."
  @spec document_symbols(String.t()) :: {:ok, [Symbol.t()]} | {:error, term()}
  def document_symbols(file_path) do
    GenServer.call(__MODULE__, {:document_symbols, file_path}, @default_timeout)
  end

  @doc """
  Get incoming calls (callers) for a symbol at position.

  Uses LSP callHierarchy/incomingCalls if supported.
  """
  @spec get_callers(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_callers(file_path, line, col) do
    GenServer.call(__MODULE__, {:get_callers, file_path, line, col}, @default_timeout)
  end

  @doc """
  Get outgoing calls (callees) for a symbol at position.

  Uses LSP callHierarchy/outgoingCalls if supported.
  """
  @spec get_callees(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def get_callees(file_path, line, col) do
    GenServer.call(__MODULE__, {:get_callees, file_path, line, col}, @default_timeout)
  end

  @doc """
  Open a file in the LSP server (notify it of file contents).

  This is required before making queries about the file.
  """
  @spec open_file(String.t()) :: :ok | {:error, term()}
  def open_file(file_path) do
    GenServer.call(__MODULE__, {:open_file, file_path}, @default_timeout)
  end

  @doc "Get tool description for agent prompts."
  @spec tool_description() :: String.t()
  def tool_description do
    """
    ## Code Navigation Tools (LSP)

    ### goto_definition(file, line, col)
    Jump to where a symbol is defined.
    Example: goto_definition("lib/noface/core/loop.ex", 100, 15)

    ### find_references(file, line, col)
    Find all usages of a symbol.
    Example: find_references("lib/noface/core/state.ex", 50, 10)

    ### list_symbols(file)
    List all functions, structs, etc. in a file.
    Example: list_symbols("lib/noface/util/bm25.ex")

    ### hover(file, line, col)
    Get type and documentation for symbol at position.
    Example: hover("lib/noface/core/loop.ex", 42, 5)

    ### get_callers(file, line, col)
    Find all functions that call this one.
    Example: get_callers("lib/noface/core/loop.ex", 100, 15)

    ### get_callees(file, line, col)
    Find all functions called by this one.
    Example: get_callees("lib/noface/core/loop.ex", 100, 15)

    Note: Line and column are 0-indexed.
    """
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      initialized: false,
      root_path: nil,
      next_id: 1,
      pending: %{},
      buffer: "",
      capabilities: %{},
      open_files: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:connect, server_cmd, root_path}, from, state) do
    # Close existing connection and reply to any pending requests with errors
    state = close_existing_connection(state)

    case find_executable(server_cmd) do
      {:ok, executable} ->
        try do
          port =
            Port.open({:spawn_executable, executable}, [
              :binary,
              :exit_status,
              :use_stdio,
              {:args, []},
              {:cd, root_path}
            ])

          new_state = %{
            state
            | port: port,
              root_path: root_path,
              next_id: 1,
              buffer: "",
              pending: %{},
              open_files: MapSet.new()
          }

          # Send initialize request asynchronously
          {id, state_with_pending} =
            send_request_async(new_state, "initialize", init_params(root_path))

          pending_with_from = Map.put(state_with_pending.pending, id, {:init, from})

          {:noreply, %{state_with_pending | pending: pending_with_from}}
        rescue
          e ->
            {:reply, {:error, Exception.message(e)}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    if state.port do
      # Send shutdown request
      {_id, new_state} = send_request_async(state, "shutdown", %{})
      send_notification(new_state, "exit", %{})
    end

    # Reply with errors to all pending requests before clearing
    Enum.each(state.pending, fn
      {_id, {:init, from}} ->
        GenServer.reply(from, {:error, :disconnected})

      {_id, {_type, from}} ->
        GenServer.reply(from, {:error, :disconnected})

      {_id, {_type, from, _extra}} ->
        GenServer.reply(from, {:error, :disconnected})
    end)

    if state.port, do: safe_close_port(state.port)

    {:reply, :ok,
     %{state | port: nil, initialized: false, pending: %{}, buffer: "", open_files: MapSet.new()}}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.initialized, state}
  end

  def handle_call({:goto_definition, file_path, line, col}, from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params = text_document_position_params(file_path, line, col)
      {id, new_state} = send_request_async(state, "textDocument/definition", params)
      pending = Map.put(new_state.pending, id, {:goto_definition, from})
      {:noreply, %{new_state | pending: pending}}
    end
  end

  def handle_call({:find_references, file_path, line, col}, from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params =
        text_document_position_params(file_path, line, col)
        |> Map.put(:context, %{includeDeclaration: true})

      {id, new_state} = send_request_async(state, "textDocument/references", params)
      pending = Map.put(new_state.pending, id, {:find_references, from})
      {:noreply, %{new_state | pending: pending}}
    end
  end

  def handle_call({:hover, file_path, line, col}, from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params = text_document_position_params(file_path, line, col)
      {id, new_state} = send_request_async(state, "textDocument/hover", params)
      pending = Map.put(new_state.pending, id, {:hover, from})
      {:noreply, %{new_state | pending: pending}}
    end
  end

  def handle_call({:document_symbols, file_path}, from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params = %{textDocument: %{uri: file_uri(file_path)}}
      {id, new_state} = send_request_async(state, "textDocument/documentSymbol", params)
      pending = Map.put(new_state.pending, id, {:document_symbols, from, file_path})
      {:noreply, %{new_state | pending: pending}}
    end
  end

  def handle_call({:get_callers, file_path, line, col}, from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      # First, prepare the call hierarchy item
      params = text_document_position_params(file_path, line, col)
      {id, new_state} = send_request_async(state, "textDocument/prepareCallHierarchy", params)
      pending = Map.put(new_state.pending, id, {:prepare_callers, from})
      {:noreply, %{new_state | pending: pending}}
    end
  end

  def handle_call({:get_callees, file_path, line, col}, from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      # First, prepare the call hierarchy item
      params = text_document_position_params(file_path, line, col)
      {id, new_state} = send_request_async(state, "textDocument/prepareCallHierarchy", params)
      pending = Map.put(new_state.pending, id, {:prepare_callees, from})
      {:noreply, %{new_state | pending: pending}}
    end
  end

  def handle_call({:open_file, file_path}, _from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      if MapSet.member?(state.open_files, file_path) do
        {:reply, :ok, state}
      else
        case File.read(file_path) do
          {:ok, content} ->
            params = %{
              textDocument: %{
                uri: file_uri(file_path),
                languageId: language_id(file_path),
                version: 1,
                text: content
              }
            }

            send_notification(state, "textDocument/didOpen", params)
            {:reply, :ok, %{state | open_files: MapSet.put(state.open_files, file_path)}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Accumulate data in buffer and parse complete messages
    buffer = state.buffer <> data
    {messages, remaining} = parse_lsp_messages(buffer)

    new_state = %{state | buffer: remaining}

    # Process each complete message
    final_state = Enum.reduce(messages, new_state, &handle_lsp_message/2)

    {:noreply, final_state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[LSP] Server exited with status #{status}")

    # Reply with errors to all pending requests
    Enum.each(state.pending, fn
      {_id, {:init, from}} ->
        GenServer.reply(from, {:error, :server_exited})

      {_id, {_type, from}} ->
        GenServer.reply(from, {:error, :server_exited})

      {_id, {_type, from, _extra}} ->
        GenServer.reply(from, {:error, :server_exited})
    end)

    {:noreply, %{state | port: nil, initialized: false, pending: %{}, buffer: ""}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private functions

  defp find_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> {:error, {:not_found, cmd}}
      path -> {:ok, path}
    end
  end

  defp safe_close_port(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  defp close_existing_connection(state) do
    # Close port if open
    if state.port, do: safe_close_port(state.port)

    # Reply with errors to all pending requests
    Enum.each(state.pending, fn
      {_id, {:init, from}} ->
        GenServer.reply(from, {:error, :reconnecting})

      {_id, {_type, from}} ->
        GenServer.reply(from, {:error, :reconnecting})

      {_id, {_type, from, _extra}} ->
        GenServer.reply(from, {:error, :reconnecting})
    end)

    %{state | port: nil, initialized: false, pending: %{}, buffer: ""}
  end

  defp init_params(root_path) do
    %{
      processId: System.pid() |> String.to_integer(),
      rootUri: file_uri(root_path),
      rootPath: root_path,
      capabilities: %{
        textDocument: %{
          definition: %{dynamicRegistration: false, linkSupport: true},
          references: %{dynamicRegistration: false},
          hover: %{
            dynamicRegistration: false,
            contentFormat: ["markdown", "plaintext"]
          },
          documentSymbol: %{
            dynamicRegistration: false,
            hierarchicalDocumentSymbolSupport: true
          },
          synchronization: %{
            dynamicRegistration: false,
            willSave: false,
            willSaveWaitUntil: false,
            didSave: true
          }
        },
        callHierarchy: %{
          dynamicRegistration: false
        }
      },
      initializationOptions: %{}
    }
  end

  defp file_uri(path) do
    "file://#{URI.encode(path)}"
  end

  defp text_document_position_params(file_path, line, col) do
    %{
      textDocument: %{uri: file_uri(file_path)},
      position: %{line: line, character: col}
    }
  end

  defp language_id(file_path) do
    ext = Path.extname(file_path)

    case ext do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".rs" -> "rust"
      ".go" -> "go"
      ".zig" -> "zig"
      ".py" -> "python"
      ".js" -> "javascript"
      ".ts" -> "typescript"
      ".tsx" -> "typescriptreact"
      ".jsx" -> "javascriptreact"
      ".rb" -> "ruby"
      ".c" -> "c"
      ".cpp" -> "cpp"
      ".h" -> "c"
      ".hpp" -> "cpp"
      _ -> "plaintext"
    end
  end

  defp send_request_async(state, method, params) do
    id = state.next_id
    message = Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
    header = "Content-Length: #{byte_size(message)}\r\n\r\n"

    try do
      Port.command(state.port, header <> message)
      {id, %{state | next_id: id + 1}}
    rescue
      ArgumentError ->
        # Port closed - return a fake ID, the error will be handled when we try to receive
        {id, %{state | next_id: id + 1}}
    end
  end

  defp send_notification(state, method, params) do
    message = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})
    header = "Content-Length: #{byte_size(message)}\r\n\r\n"

    try do
      Port.command(state.port, header <> message)
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  # Parse LSP messages from buffer (Content-Length header + JSON body)
  defp parse_lsp_messages(buffer) do
    parse_lsp_messages(buffer, [])
  end

  defp parse_lsp_messages(buffer, acc) do
    case parse_one_message(buffer) do
      {:ok, message, rest} ->
        parse_lsp_messages(rest, [message | acc])

      :incomplete ->
        {Enum.reverse(acc), buffer}
    end
  end

  defp parse_one_message(buffer) do
    # LSP messages have headers (including Content-Length) followed by \r\n\r\n and then the body.
    # We need to handle multiple headers - servers may send Content-Type, etc.
    # Format: "Header1: value\r\nHeader2: value\r\n\r\n{json body}"
    case :binary.match(buffer, <<"\r\n\r\n">>) do
      {header_end, 4} ->
        headers = binary_part(buffer, 0, header_end)
        body_start = header_end + 4

        case extract_content_length(headers) do
          {:ok, content_length} ->
            if byte_size(buffer) >= body_start + content_length do
              body = binary_part(buffer, body_start, content_length)

              rest =
                binary_part(
                  buffer,
                  body_start + content_length,
                  byte_size(buffer) - body_start - content_length
                )

              case Jason.decode(body) do
                {:ok, message} -> {:ok, message, rest}
                {:error, _} -> :incomplete
              end
            else
              :incomplete
            end

          :error ->
            # No Content-Length found - malformed message, skip this data
            :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp extract_content_length(headers) do
    # Parse headers looking for Content-Length
    case Regex.run(~r/Content-Length:\s*(\d+)/i, headers) do
      [_, length_str] -> {:ok, String.to_integer(length_str)}
      nil -> :error
    end
  end

  # Handle a complete LSP message
  defp handle_lsp_message(message, state) do
    cond do
      # Response to a request we made
      Map.has_key?(message, "id") and Map.has_key?(message, "result") ->
        handle_response(message["id"], message["result"], state)

      # Error response
      Map.has_key?(message, "id") and Map.has_key?(message, "error") ->
        handle_error_response(message["id"], message["error"], state)

      # Notification from server (no id)
      Map.has_key?(message, "method") ->
        handle_server_notification(message["method"], message["params"], state)

      true ->
        Logger.debug("[LSP] Unknown message: #{inspect(message)}")
        state
    end
  end

  defp handle_response(id, result, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.debug("[LSP] Received response for unknown request #{id}")
        state

      {{:init, from}, pending} ->
        # Initialize response - store capabilities and send initialized notification
        capabilities = result["capabilities"] || %{}
        send_notification(state, "initialized", %{})
        GenServer.reply(from, :ok)
        %{state | pending: pending, initialized: true, capabilities: capabilities}

      {{:goto_definition, from}, pending} ->
        location = parse_location_result(result)
        GenServer.reply(from, {:ok, location})
        %{state | pending: pending}

      {{:find_references, from}, pending} ->
        locations = parse_locations(result)
        GenServer.reply(from, {:ok, locations})
        %{state | pending: pending}

      {{:hover, from}, pending} ->
        content = parse_hover(result)
        GenServer.reply(from, {:ok, content})
        %{state | pending: pending}

      {{:document_symbols, from, file_path}, pending} ->
        symbols = parse_symbols(result, file_path)
        GenServer.reply(from, {:ok, symbols})
        %{state | pending: pending}

      {{:prepare_callers, from}, pending} ->
        # Result is a list of CallHierarchyItem, we need to make requests for each
        case result do
          items when is_list(items) and items != [] ->
            # Request incoming calls for all items and aggregate results
            {new_state, request_ids} =
              Enum.reduce(items, {%{state | pending: pending}, []}, fn item, {st, ids} ->
                {new_id, updated_state} =
                  send_request_async(st, "callHierarchy/incomingCalls", %{item: item})

                {updated_state, [new_id | ids]}
              end)

            # Track all request IDs to aggregate results when all complete
            aggregator = {:aggregate_calls, from, :incoming, length(items), []}

            new_pending =
              Enum.reduce(request_ids, new_state.pending, fn id, pend ->
                Map.put(pend, id, aggregator)
              end)

            %{new_state | pending: new_pending}

          _ ->
            GenServer.reply(from, {:ok, []})
            %{state | pending: pending}
        end

      {{:prepare_callees, from}, pending} ->
        # Result is a list of CallHierarchyItem, we need to make requests for each
        case result do
          items when is_list(items) and items != [] ->
            # Request outgoing calls for all items and aggregate results
            {new_state, request_ids} =
              Enum.reduce(items, {%{state | pending: pending}, []}, fn item, {st, ids} ->
                {new_id, updated_state} =
                  send_request_async(st, "callHierarchy/outgoingCalls", %{item: item})

                {updated_state, [new_id | ids]}
              end)

            # Track all request IDs to aggregate results when all complete
            aggregator = {:aggregate_calls, from, :outgoing, length(items), []}

            new_pending =
              Enum.reduce(request_ids, new_state.pending, fn id, pend ->
                Map.put(pend, id, aggregator)
              end)

            %{new_state | pending: new_pending}

          _ ->
            GenServer.reply(from, {:ok, []})
            %{state | pending: pending}
        end

      {{:incoming_calls, from}, pending} ->
        calls = parse_call_hierarchy_calls(result, :incoming)
        GenServer.reply(from, {:ok, calls})
        %{state | pending: pending}

      {{:outgoing_calls, from}, pending} ->
        calls = parse_call_hierarchy_calls(result, :outgoing)
        GenServer.reply(from, {:ok, calls})
        %{state | pending: pending}

      # Aggregator for multiple call hierarchy items
      {{:aggregate_calls, from, direction, expected_count, accumulated}, pending} ->
        calls = parse_call_hierarchy_calls(result, direction)
        new_accumulated = calls ++ accumulated

        # Check if this is the last response
        # Count how many other pending requests share this aggregator
        other_count =
          Enum.count(pending, fn
            {_id, {:aggregate_calls, ^from, ^direction, ^expected_count, _}} -> true
            _ -> false
          end)

        if other_count == 0 do
          # All responses received, reply with aggregated results
          # Remove duplicates by unique (name, uri, range)
          unique_calls =
            Enum.uniq_by(new_accumulated, fn call ->
              {call[:name], call[:uri], call[:range]}
            end)

          GenServer.reply(from, {:ok, unique_calls})
          %{state | pending: pending}
        else
          # Still waiting for more responses - update all related pending entries
          updated_pending =
            Enum.reduce(pending, %{}, fn
              {id, {:aggregate_calls, ^from, ^direction, ^expected_count, _}}, acc ->
                Map.put(
                  acc,
                  id,
                  {:aggregate_calls, from, direction, expected_count, new_accumulated}
                )

              {id, val}, acc ->
                Map.put(acc, id, val)
            end)

          %{state | pending: updated_pending}
        end

      {unknown, pending} ->
        Logger.debug("[LSP] Unhandled pending type: #{inspect(unknown)}")
        %{state | pending: pending}
    end
  end

  defp handle_error_response(id, error, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.warning("[LSP] Error for unknown request #{id}: #{inspect(error)}")
        state

      {{:init, from}, pending} ->
        GenServer.reply(from, {:error, error["message"] || "initialization failed"})
        %{state | pending: pending}

      # Handle aggregate_calls error - reply with error immediately
      {{:aggregate_calls, from, direction, expected_count, _accumulated}, pending} ->
        # Remove all other pending requests for this aggregator
        cleaned_pending =
          Enum.reject(pending, fn
            {_id, {:aggregate_calls, ^from, ^direction, ^expected_count, _}} -> true
            _ -> false
          end)
          |> Enum.into(%{})

        GenServer.reply(from, {:error, error["message"] || "request failed"})
        %{state | pending: cleaned_pending}

      {{_type, from}, pending} ->
        GenServer.reply(from, {:error, error["message"] || "request failed"})
        %{state | pending: pending}

      {{_type, from, _extra}, pending} ->
        GenServer.reply(from, {:error, error["message"] || "request failed"})
        %{state | pending: pending}
    end
  end

  defp handle_server_notification(method, params, state) do
    case method do
      "window/logMessage" ->
        level = params["type"]
        message = params["message"]

        case level do
          1 -> Logger.error("[LSP] #{message}")
          2 -> Logger.warning("[LSP] #{message}")
          3 -> Logger.info("[LSP] #{message}")
          _ -> Logger.debug("[LSP] #{message}")
        end

      "textDocument/publishDiagnostics" ->
        # We could store diagnostics here if needed
        Logger.debug(
          "[LSP] Diagnostics for #{params["uri"]}: #{length(params["diagnostics"] || [])} items"
        )

      _ ->
        Logger.debug("[LSP] Notification: #{method}")
    end

    state
  end

  # Result parsers

  defp parse_location_result(nil), do: nil
  defp parse_location_result([]), do: nil
  defp parse_location_result([first | _]), do: parse_location(first)
  defp parse_location_result(result), do: parse_location(result)

  defp parse_location(nil), do: nil

  defp parse_location(%{"uri" => uri, "range" => range}) do
    %Location{
      uri: uri,
      line: range["start"]["line"],
      character: range["start"]["character"],
      end_line: range["end"]["line"],
      end_character: range["end"]["character"]
    }
  end

  defp parse_location(%{"targetUri" => uri, "targetRange" => range}) do
    %Location{
      uri: uri,
      line: range["start"]["line"],
      character: range["start"]["character"],
      end_line: range["end"]["line"],
      end_character: range["end"]["character"]
    }
  end

  defp parse_location(_), do: nil

  defp parse_locations(nil), do: []

  defp parse_locations(list) when is_list(list) do
    list
    |> Enum.map(&parse_location/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_locations(_), do: []

  defp parse_hover(nil), do: nil

  defp parse_hover(%{"contents" => contents}) do
    parse_hover_contents(contents)
  end

  defp parse_hover(_), do: nil

  defp parse_hover_contents(%{"kind" => _, "value" => value}), do: value
  defp parse_hover_contents(%{"value" => value}), do: value
  defp parse_hover_contents(str) when is_binary(str), do: str

  defp parse_hover_contents(list) when is_list(list) do
    list
    |> Enum.map(&parse_hover_contents/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp parse_hover_contents(_), do: nil

  defp parse_symbols(nil, _file_path), do: []

  defp parse_symbols(list, file_path) when is_list(list) do
    list
    |> Enum.flat_map(&parse_symbol(&1, file_path))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_symbols(_, _), do: []

  # SymbolInformation format
  defp parse_symbol(%{"name" => name, "kind" => kind, "location" => location}, _file_path) do
    [
      %Symbol{
        name: name,
        kind: Map.get(@symbol_kinds, kind, :unknown),
        location: parse_location(location),
        container: nil
      }
    ]
  end

  # DocumentSymbol format (hierarchical) - flatten the tree
  defp parse_symbol(
         %{"name" => name, "kind" => kind, "range" => range} = sym,
         file_path
       ) do
    location = %Location{
      uri: file_uri(file_path),
      line: range["start"]["line"],
      character: range["start"]["character"],
      end_line: range["end"]["line"],
      end_character: range["end"]["character"]
    }

    this_symbol = %Symbol{
      name: name,
      kind: Map.get(@symbol_kinds, kind, :unknown),
      location: location,
      container: nil
    }

    # Recursively parse children
    children =
      case sym["children"] do
        nil -> []
        kids -> Enum.flat_map(kids, &parse_symbol(&1, file_path))
      end

    [this_symbol | children]
  end

  defp parse_symbol(_, _), do: []

  defp parse_call_hierarchy_calls(nil, _direction), do: []

  defp parse_call_hierarchy_calls(list, direction) when is_list(list) do
    Enum.map(list, fn call ->
      item_key = if direction == :incoming, do: "from", else: "to"
      item = call[item_key] || %{}

      %{
        name: item["name"],
        kind: Map.get(@symbol_kinds, item["kind"], :unknown),
        uri: item["uri"],
        range: item["range"],
        from_ranges: call["fromRanges"]
      }
    end)
  end

  defp parse_call_hierarchy_calls(_, _), do: []
end

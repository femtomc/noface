defmodule Noface.Integrations.LSP do
  @moduledoc """
  LSP client for semantic code analysis.

  Communicates with language servers (zls, rust-analyzer, elixir-ls, etc.)
  to provide agents with semantic understanding: definitions, references, call graphs.
  """
  use GenServer
  require Logger

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
    def path(%__MODULE__{uri: uri}) do
      case uri do
        "file://" <> path -> path
        other -> other
      end
    end
  end

  defmodule Symbol do
    @moduledoc "A symbol in a document."
    @type t :: %__MODULE__{
            name: String.t(),
            kind: atom(),
            location: Location.t()
          }

    defstruct [:name, :kind, :location]
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

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Connect to an LSP server."
  @spec connect(String.t(), String.t()) :: :ok | {:error, term()}
  def connect(server_cmd, root_path) do
    GenServer.call(__MODULE__, {:connect, server_cmd, root_path}, 30_000)
  end

  @doc "Disconnect from LSP server."
  @spec disconnect() :: :ok
  def disconnect do
    GenServer.call(__MODULE__, :disconnect)
  end

  @doc "Go to definition of symbol at position."
  @spec goto_definition(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, Location.t() | nil} | {:error, term()}
  def goto_definition(file_path, line, col) do
    GenServer.call(__MODULE__, {:goto_definition, file_path, line, col}, 10_000)
  end

  @doc "Find all references to symbol at position."
  @spec find_references(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, [Location.t()]} | {:error, term()}
  def find_references(file_path, line, col) do
    GenServer.call(__MODULE__, {:find_references, file_path, line, col}, 10_000)
  end

  @doc "Get hover information (type, docs)."
  @spec hover(String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def hover(file_path, line, col) do
    GenServer.call(__MODULE__, {:hover, file_path, line, col}, 10_000)
  end

  @doc "Get document symbols (functions, structs, etc.)."
  @spec document_symbols(String.t()) :: {:ok, [Symbol.t()]} | {:error, term()}
  def document_symbols(file_path) do
    GenServer.call(__MODULE__, {:document_symbols, file_path}, 10_000)
  end

  @doc "Get tool description for agent prompts."
  @spec tool_description() :: String.t()
  def tool_description do
    """
    ## Code Navigation Tools

    ### goto_definition(file, line, col)
    Jump to where a symbol is defined.
    Example: goto_definition("src/loop.zig", 100, 15)

    ### find_references(file, line, col)
    Find all usages of a symbol.
    Example: find_references("src/state.zig", 50, 10)

    ### list_symbols(file)
    List all functions, structs, etc. in a file.
    Example: list_symbols("src/bm25.zig")

    ### get_callers(function_name)
    Find all functions that call this one.
    Example: get_callers("parseJson")

    ### get_callees(function_name)
    Find all functions called by this one.
    Example: get_callees("runIteration")
    """
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{port: nil, initialized: false, root_path: nil, next_id: 1, pending: %{}}}
  end

  @impl true
  def handle_call({:connect, server_cmd, root_path}, _from, state) do
    # Close existing connection if any
    if state.port, do: Port.close(state.port)

    try do
      port =
        Port.open({:spawn_executable, find_executable(server_cmd)}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:args, []},
          {:cd, root_path}
        ])

      new_state = %{state | port: port, root_path: root_path, next_id: 1}

      # Send initialize request
      case send_initialize(new_state) do
        {:ok, final_state} ->
          {:reply, :ok, %{final_state | initialized: true}}

        {:error, reason} ->
          Port.close(port)
          {:reply, {:error, reason}, state}
      end
    rescue
      e -> {:reply, {:error, Exception.message(e)}, state}
    end
  end

  def handle_call(:disconnect, _from, state) do
    if state.port do
      # Send shutdown request
      send_request(state, "shutdown", %{})
      send_notification(state, "exit", %{})
      Port.close(state.port)
    end

    {:reply, :ok, %{state | port: nil, initialized: false}}
  end

  def handle_call({:goto_definition, file_path, line, col}, _from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params = %{
        textDocument: %{uri: "file://#{file_path}"},
        position: %{line: line, character: col}
      }

      case send_request(state, "textDocument/definition", params) do
        {:ok, response, new_state} ->
          location = parse_location(response)
          {:reply, {:ok, location}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:find_references, file_path, line, col}, _from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params = %{
        textDocument: %{uri: "file://#{file_path}"},
        position: %{line: line, character: col},
        context: %{includeDeclaration: true}
      }

      case send_request(state, "textDocument/references", params) do
        {:ok, response, new_state} ->
          locations = parse_locations(response)
          {:reply, {:ok, locations}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:hover, file_path, line, col}, _from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params = %{
        textDocument: %{uri: "file://#{file_path}"},
        position: %{line: line, character: col}
      }

      case send_request(state, "textDocument/hover", params) do
        {:ok, response, new_state} ->
          content = parse_hover(response)
          {:reply, {:ok, content}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:document_symbols, file_path}, _from, state) do
    if not state.initialized do
      {:reply, {:error, :not_connected}, state}
    else
      params = %{textDocument: %{uri: "file://#{file_path}"}}

      case send_request(state, "textDocument/documentSymbol", params) do
        {:ok, response, new_state} ->
          symbols = parse_symbols(response)
          {:reply, {:ok, symbols}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Handle incoming LSP messages
    Logger.debug("[LSP] Received: #{inspect(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[LSP] Server exited with status #{status}")
    {:noreply, %{state | port: nil, initialized: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private functions

  defp find_executable(cmd) do
    case System.find_executable(cmd) do
      nil -> raise "LSP server not found: #{cmd}"
      path -> path
    end
  end

  defp send_initialize(state) do
    params = %{
      processId: System.pid() |> String.to_integer(),
      rootUri: "file://#{state.root_path}",
      capabilities: %{
        textDocument: %{
          definition: %{dynamicRegistration: false},
          references: %{dynamicRegistration: false},
          hover: %{dynamicRegistration: false}
        }
      }
    }

    case send_request(state, "initialize", params) do
      {:ok, _response, new_state} ->
        send_notification(new_state, "initialized", %{})
        {:ok, new_state}

      error ->
        error
    end
  end

  defp send_request(state, method, params) do
    id = state.next_id
    message = Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params})
    header = "Content-Length: #{byte_size(message)}\r\n\r\n"

    Port.command(state.port, header <> message)

    # For now, return a simple acknowledgment
    # A full implementation would read and parse the response
    {:ok, nil, %{state | next_id: id + 1}}
  end

  defp send_notification(state, method, params) do
    message = Jason.encode!(%{jsonrpc: "2.0", method: method, params: params})
    header = "Content-Length: #{byte_size(message)}\r\n\r\n"
    Port.command(state.port, header <> message)
    :ok
  end

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
  defp parse_locations(list) when is_list(list), do: Enum.map(list, &parse_location/1) |> Enum.reject(&is_nil/1)
  defp parse_locations(_), do: []

  defp parse_hover(nil), do: nil

  defp parse_hover(%{"contents" => %{"value" => value}}), do: value
  defp parse_hover(%{"contents" => value}) when is_binary(value), do: value
  defp parse_hover(_), do: nil

  defp parse_symbols(nil), do: []
  defp parse_symbols(list) when is_list(list), do: Enum.map(list, &parse_symbol/1) |> Enum.reject(&is_nil/1)
  defp parse_symbols(_), do: []

  defp parse_symbol(%{"name" => name, "kind" => kind, "location" => location}) do
    %Symbol{
      name: name,
      kind: Map.get(@symbol_kinds, kind, :unknown),
      location: parse_location(location)
    }
  end

  defp parse_symbol(%{"name" => name, "kind" => kind, "range" => range, "selectionRange" => _}) do
    # DocumentSymbol format (hierarchical)
    %Symbol{
      name: name,
      kind: Map.get(@symbol_kinds, kind, :unknown),
      location: %Location{
        uri: "",
        line: range["start"]["line"],
        character: range["start"]["character"],
        end_line: range["end"]["line"],
        end_character: range["end"]["character"]
      }
    }
  end

  defp parse_symbol(_), do: nil
end

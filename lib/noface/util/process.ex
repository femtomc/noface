defmodule Noface.Util.Process do
  @moduledoc """
  Process execution utilities for running external commands.

  Provides functions for running commands, capturing output, and streaming.
  Leverages Erlang's Port for process management.
  """

  @type command_result :: %{
          stdout: String.t(),
          stderr: String.t(),
          exit_code: non_neg_integer()
        }

  @doc """
  Run a command and capture output.
  """
  @spec run([String.t()]) :: {:ok, command_result()} | {:error, term()}
  def run([cmd | args]) do
    case System.cmd(cmd, args, stderr_to_stdout: false) do
      {stdout, exit_code} ->
        {:ok,
         %{
           stdout: stdout,
           stderr: "",
           exit_code: exit_code
         }}
    end
  rescue
    e in ErlangError ->
      {:error, {:command_failed, e}}
  end

  @doc """
  Run a shell command (via /bin/sh -c).
  """
  @spec shell(String.t()) :: {:ok, command_result()} | {:error, term()}
  def shell(command) do
    run(["/bin/sh", "-c", command])
  end

  @doc """
  Check if a command exists in PATH.
  """
  @spec command_exists?(String.t()) :: boolean()
  def command_exists?(command) do
    case shell("which #{command}") do
      {:ok, %{exit_code: 0}} -> true
      _ -> false
    end
  end

  defmodule StreamingProcess do
    @moduledoc """
    A streaming process that allows reading output line by line with timeout support.
    """

    defstruct [:port, :partial_buffer, :alive?]

    @type t :: %__MODULE__{
            port: port(),
            partial_buffer: String.t(),
            alive?: boolean()
          }

    @type timed_read_result ::
            {:line, String.t()}
            | :timeout
            | :eof

    @doc """
    Spawn a streaming process.
    """
    @spec spawn([String.t()], keyword()) :: {:ok, t()} | {:error, term()}
    def spawn(argv, opts \\ []) do
      [cmd | args] = argv

      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args}
      ]

      port_opts =
        if env = Keyword.get(opts, :env) do
          [{:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)} | port_opts]
        else
          port_opts
        end

      port_opts =
        if cd = Keyword.get(opts, :cd) do
          [{:cd, to_charlist(cd)} | port_opts]
        else
          port_opts
        end

      try do
        port = Port.open({:spawn_executable, System.find_executable(cmd)}, port_opts)
        {:ok, %__MODULE__{port: port, partial_buffer: "", alive?: true}}
      rescue
        e -> {:error, e}
      end
    end

    @doc """
    Read a line from the process with timeout (in seconds).
    Returns {:line, data}, :timeout, or :eof.
    """
    @spec read_line_with_timeout(t(), non_neg_integer()) :: {timed_read_result(), t()}
    def read_line_with_timeout(%__MODULE__{alive?: false} = proc, _timeout) do
      {:eof, proc}
    end

    def read_line_with_timeout(
          %__MODULE__{port: port, partial_buffer: buffer} = proc,
          timeout_seconds
        ) do
      timeout_ms = if timeout_seconds == 0, do: :infinity, else: timeout_seconds * 1000

      receive do
        {^port, {:data, data}} ->
          full_buffer = buffer <> data

          case String.split(full_buffer, "\n", parts: 2) do
            [line, rest] ->
              {{:line, line}, %{proc | partial_buffer: rest}}

            [incomplete] ->
              # No complete line yet, keep reading
              read_line_with_timeout(%{proc | partial_buffer: incomplete}, timeout_seconds)
          end

        {^port, {:exit_status, _code}} ->
          if buffer != "" do
            {{:line, buffer}, %{proc | partial_buffer: "", alive?: false}}
          else
            {:eof, %{proc | alive?: false}}
          end
      after
        timeout_ms ->
          {:timeout, proc}
      end
    end

    @doc """
    Wait for the process to complete and return exit code.
    """
    @spec wait(t()) :: {:ok, non_neg_integer(), t()} | {:error, term()}
    def wait(%__MODULE__{port: _port, alive?: false} = proc) do
      {:ok, 0, proc}
    end

    def wait(%__MODULE__{port: port} = proc) do
      receive do
        {^port, {:exit_status, code}} ->
          {:ok, code, %{proc | alive?: false}}

        {^port, {:data, _data}} ->
          # Drain remaining data
          wait(proc)
      after
        60_000 ->
          {:error, :timeout}
      end
    end

    @doc """
    Kill the process.
    """
    @spec kill(t()) :: :ok
    def kill(%__MODULE__{port: port, alive?: true} = _proc) do
      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end

      :ok
    end

    def kill(_proc), do: :ok

    @doc """
    Check if process is still running.
    """
    @spec running?(t()) :: boolean()
    def running?(%__MODULE__{alive?: alive?}), do: alive?
  end
end

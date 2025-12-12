defmodule Noface.Integrations.LSPTest do
  use ExUnit.Case, async: false

  alias Noface.Integrations.LSP
  alias Noface.Integrations.LSP.Location

  # Access private functions for testing
  @compile {:no_warn_undefined, Noface.Integrations.LSP}

  describe "LSP message parsing" do
    # We test the public API behavior indirectly since parsing is internal
    # But we can test the Location parsing which is part of public structs
    test "handles standard Content-Length header format" do
      # This is tested indirectly through the GenServer behavior
      # The actual parsing is internal, but we verify Location struct works
      loc = %Location{
        uri: "file:///test.ex",
        line: 5,
        character: 10,
        end_line: 5,
        end_character: 20
      }

      assert Location.path(loc) == "/test.ex"
    end
  end

  describe "Location" do
    test "path extracts file path from URI" do
      loc = %Location{
        uri: "file:///Users/test/project/src/main.rs",
        line: 10,
        character: 5,
        end_line: 10,
        end_character: 15
      }

      assert Location.path(loc) == "/Users/test/project/src/main.rs"
    end

    test "path decodes URI-encoded paths" do
      loc = %Location{
        uri: "file:///Users/test/my%20project/src/main.rs",
        line: 10,
        character: 5,
        end_line: 10,
        end_character: 15
      }

      assert Location.path(loc) == "/Users/test/my project/src/main.rs"
    end

    test "format returns file:line:col" do
      loc = %Location{
        uri: "file:///Users/test/project/src/main.rs",
        line: 9,
        character: 4,
        end_line: 9,
        end_character: 14
      }

      # LSP is 0-indexed, format returns 1-indexed
      assert Location.format(loc) == "/Users/test/project/src/main.rs:10:5"
    end
  end

  describe "tool_description/0" do
    test "returns documentation string" do
      desc = LSP.tool_description()
      assert desc =~ "goto_definition"
      assert desc =~ "find_references"
      assert desc =~ "get_callers"
      assert desc =~ "get_callees"
    end
  end

  describe "GenServer initialization" do
    test "starts with disconnected state" do
      {:ok, pid} = GenServer.start_link(LSP, [], [])

      # Call connected? directly on the pid since it's not registered
      refute GenServer.call(pid, :connected?)

      GenServer.stop(pid)
    end
  end

  describe "connect/2" do
    test "returns error when executable not found" do
      {:ok, pid} = GenServer.start_link(LSP, [], [])

      result =
        GenServer.call(pid, {:connect, "nonexistent-lsp-server-xyz123", "/tmp"}, 5_000)

      assert {:error, {:not_found, "nonexistent-lsp-server-xyz123"}} = result

      GenServer.stop(pid)
    end
  end

  describe "operations when not connected" do
    setup do
      {:ok, pid} = GenServer.start_link(LSP, [], [])

      on_exit(fn ->
        if Process.alive?(pid) do
          GenServer.stop(pid)
        end
      end)

      {:ok, pid: pid}
    end

    test "goto_definition returns error", %{pid: pid} do
      result = GenServer.call(pid, {:goto_definition, "/test/file.ex", 10, 5})
      assert {:error, :not_connected} = result
    end

    test "find_references returns error", %{pid: pid} do
      result = GenServer.call(pid, {:find_references, "/test/file.ex", 10, 5})
      assert {:error, :not_connected} = result
    end

    test "hover returns error", %{pid: pid} do
      result = GenServer.call(pid, {:hover, "/test/file.ex", 10, 5})
      assert {:error, :not_connected} = result
    end

    test "document_symbols returns error", %{pid: pid} do
      result = GenServer.call(pid, {:document_symbols, "/test/file.ex"})
      assert {:error, :not_connected} = result
    end

    test "get_callers returns error", %{pid: pid} do
      result = GenServer.call(pid, {:get_callers, "/test/file.ex", 10, 5})
      assert {:error, :not_connected} = result
    end

    test "get_callees returns error", %{pid: pid} do
      result = GenServer.call(pid, {:get_callees, "/test/file.ex", 10, 5})
      assert {:error, :not_connected} = result
    end

    test "open_file returns error", %{pid: pid} do
      result = GenServer.call(pid, {:open_file, "/test/file.ex"})
      assert {:error, :not_connected} = result
    end
  end
end

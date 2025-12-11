defmodule Noface.Tools do
  @moduledoc """
  Manages local installation of CLI tools that noface depends on.

  Tools are installed to `.noface/bin/` and `.noface/node_modules/`.
  This gives noface control over versions and enables auto-updates.

  Supported tools:
  - claude (npm: @anthropic-ai/claude-code)
  - codex (npm: @openai/codex)
  - bd/beads (binary download)
  - gh (binary download from GitHub)
  - jj (binary download from GitHub)
  """
  require Logger

  @noface_dir ".noface"
  @bin_dir ".noface/bin"
  @versions_file ".noface/versions.json"

  @tools %{
    claude: %{
      type: :npm,
      package: "@anthropic-ai/claude-code",
      binary: "claude"
    },
    codex: %{
      type: :npm,
      package: "@openai/codex",
      binary: "codex"
    },
    bd: %{
      type: :binary,
      repo: "femtomc/beads",
      binary: "bd"
    },
    gh: %{
      type: :binary,
      repo: "cli/cli",
      binary: "gh"
    },
    jj: %{
      type: :binary,
      repo: "martinvonz/jj",
      binary: "jj"
    }
  }

  @doc """
  Initialize the noface tools directory and install dependencies.
  """
  @spec init(keyword()) :: :ok | {:error, term()}
  def init(opts \\ []) do
    Logger.info("[TOOLS] Initializing noface tools directory")

    with :ok <- ensure_directories(),
         :ok <- create_package_json(),
         :ok <- install_npm_tools(opts),
         :ok <- install_binary_tools(opts),
         :ok <- create_wrapper_scripts() do
      Logger.info("[TOOLS] Initialization complete")
      :ok
    end
  end

  @doc """
  Get the path to a tool binary.
  Falls back to system PATH if not installed locally.
  """
  @spec bin_path(atom()) :: String.t()
  def bin_path(tool) do
    local_path = Path.join(@bin_dir, to_string(tool))

    if File.exists?(local_path) do
      Path.absname(local_path)
    else
      to_string(tool)
    end
  end

  @doc """
  Check if a tool is installed locally.
  """
  @spec installed?(atom()) :: boolean()
  def installed?(tool) do
    local_path = Path.join(@bin_dir, to_string(tool))
    File.exists?(local_path)
  end

  @doc """
  Get installed versions of all tools.
  """
  @spec versions() :: map()
  def versions do
    case File.read(@versions_file) do
      {:ok, content} -> Jason.decode!(content)
      {:error, _} -> %{}
    end
  end

  @doc """
  Check for updates to installed tools.
  Returns updates found and any errors encountered during checks.
  """
  @spec check_updates() :: {:ok, map()} | {:ok, map(), [{atom(), term()}]} | {:error, term()}
  def check_updates do
    current = versions()

    {updates, errors} =
      @tools
      |> Enum.reduce({%{}, []}, fn {name, spec}, {updates, errors} ->
        case check_tool_update(name, spec, current) do
          {:update_available, current_ver, latest_ver} ->
            {Map.put(updates, name, %{current: current_ver, latest: latest_ver}), errors}

          :up_to_date ->
            {updates, errors}

          {:error, reason} ->
            {updates, [{name, reason} | errors]}
        end
      end)

    case errors do
      [] -> {:ok, updates}
      _ -> {:ok, updates, Enum.reverse(errors)}
    end
  end

  @doc """
  Update a specific tool to the latest version.
  """
  @spec update(atom()) :: :ok | {:error, term()}
  def update(tool) do
    case Map.get(@tools, tool) do
      nil ->
        {:error, :unknown_tool}

      spec ->
        Logger.info("[TOOLS] Updating #{tool}")
        install_tool(tool, spec, force: true)
    end
  end

  @doc """
  Update all tools to latest versions.
  """
  @spec update_all() :: :ok | {:error, term()}
  def update_all do
    Enum.each(@tools, fn {name, spec} ->
      install_tool(name, spec, force: true)
    end)

    :ok
  end

  # Private functions

  defp ensure_directories do
    File.mkdir_p!(@noface_dir)
    File.mkdir_p!(@bin_dir)
    File.mkdir_p!(Path.join(@noface_dir, "node_modules"))
    :ok
  end

  defp create_package_json do
    package_json = Path.join(@noface_dir, "package.json")

    unless File.exists?(package_json) do
      content =
        Jason.encode!(
          %{
            "name" => "noface-tools",
            "version" => "1.0.0",
            "private" => true,
            "dependencies" => %{}
          },
          pretty: true
        )

      File.write!(package_json, content)
    end

    :ok
  end

  defp install_npm_tools(opts) do
    npm_tools =
      @tools
      |> Enum.filter(fn {_, spec} -> spec.type == :npm end)

    Enum.each(npm_tools, fn {name, spec} ->
      install_tool(name, spec, opts)
    end)

    :ok
  end

  defp install_binary_tools(opts) do
    binary_tools =
      @tools
      |> Enum.filter(fn {_, spec} -> spec.type == :binary end)

    Enum.each(binary_tools, fn {name, spec} ->
      install_tool(name, spec, opts)
    end)

    :ok
  end

  defp install_tool(name, %{type: :npm} = spec, opts) do
    force = Keyword.get(opts, :force, false)
    bin_path = Path.join(@bin_dir, spec.binary)

    if force or not File.exists?(bin_path) do
      Logger.info("[TOOLS] Installing #{name} via npm...")

      case System.cmd("npm", ["install", spec.package],
             cd: @noface_dir,
             stderr_to_stdout: true
           ) do
        {_, 0} ->
          # Create wrapper script
          create_npm_wrapper(spec.binary, spec.package)
          update_version(name, get_npm_version(spec.package))
          Logger.info("[TOOLS] Installed #{name}")
          :ok

        {output, _} ->
          Logger.warning("[TOOLS] Failed to install #{name}: #{output}")
          {:error, output}
      end
    else
      :ok
    end
  end

  defp install_tool(name, %{type: :binary} = spec, opts) do
    force = Keyword.get(opts, :force, false)
    bin_path = Path.join(@bin_dir, spec.binary)

    if force or not File.exists?(bin_path) do
      Logger.info("[TOOLS] Installing #{name} from GitHub...")

      case download_binary(spec.repo, spec.binary) do
        {:ok, version} ->
          update_version(name, version)
          Logger.info("[TOOLS] Installed #{name} v#{version}")
          :ok

        {:error, reason} ->
          Logger.warning("[TOOLS] Failed to install #{name}: #{inspect(reason)}")
          # Try to use system binary as fallback
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp create_wrapper_scripts do
    # Create wrapper scripts for npm packages
    @tools
    |> Enum.filter(fn {_, spec} -> spec.type == :npm end)
    |> Enum.each(fn {_, spec} ->
      create_npm_wrapper(spec.binary, spec.package)
    end)

    :ok
  end

  defp create_npm_wrapper(binary, _package) do
    wrapper_path = Path.join(@bin_dir, binary)
    node_modules = Path.join(@noface_dir, "node_modules")

    # Find the actual binary in node_modules/.bin
    npm_bin = Path.join([node_modules, ".bin", binary])

    script = """
    #!/bin/sh
    exec "#{Path.absname(npm_bin)}" "$@"
    """

    File.write!(wrapper_path, script)
    File.chmod!(wrapper_path, 0o755)
  end

  defp download_binary(repo, binary) do
    # Get latest release from GitHub API
    api_url = "https://api.github.com/repos/#{repo}/releases/latest"

    case Req.get(api_url, headers: [{"accept", "application/vnd.github.v3+json"}]) do
      {:ok, %{status: 200, body: release}} ->
        version = release["tag_name"]
        assets = release["assets"] || []

        # Find appropriate asset for this platform
        case find_asset(assets, binary) do
          nil ->
            {:error, :no_compatible_asset}

          asset ->
            download_url = asset["browser_download_url"]
            download_and_extract(download_url, binary, version)
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_asset(assets, _binary) do
    os =
      case :os.type() do
        {:unix, :darwin} -> "darwin"
        {:unix, _} -> "linux"
        {:win32, _} -> "windows"
      end

    arch =
      case :erlang.system_info(:system_architecture) |> to_string() do
        "aarch64" <> _ -> "arm64"
        "x86_64" <> _ -> "amd64"
        "arm" <> _ -> "arm64"
        _ -> "amd64"
      end

    # Try to find matching asset
    # Fallback: just find one for this OS
    Enum.find(assets, fn asset ->
      name = String.downcase(asset["name"] || "")

      String.contains?(name, os) and
        (String.contains?(name, arch) or String.contains?(name, "universal")) and
        not String.contains?(name, ".sha") and
        not String.contains?(name, ".sig")
    end) ||
      Enum.find(assets, fn asset ->
        name = String.downcase(asset["name"] || "")

        String.contains?(name, os) and
          not String.contains?(name, ".sha") and
          not String.contains?(name, ".sig")
      end)
  end

  defp download_and_extract(url, binary, version) do
    Logger.debug("[TOOLS] Downloading #{url}")

    case Req.get(url, follow_redirects: true, max_redirects: 5) do
      {:ok, %{status: 200, body: body}} ->
        extract_binary(body, url, binary)
        {:ok, version}

      {:ok, %{status: status}} ->
        {:error, {:download_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_binary(body, url, binary) do
    bin_path = Path.join(@bin_dir, binary)
    tmp_dir = Path.join(System.tmp_dir!(), "noface-#{:rand.uniform(100_000)}")

    File.mkdir_p!(tmp_dir)

    try do
      cond do
        String.ends_with?(url, ".tar.gz") or String.ends_with?(url, ".tgz") ->
          tar_path = Path.join(tmp_dir, "archive.tar.gz")
          File.write!(tar_path, body)
          System.cmd("tar", ["-xzf", tar_path, "-C", tmp_dir])
          find_and_copy_binary(tmp_dir, binary, bin_path)

        String.ends_with?(url, ".zip") ->
          zip_path = Path.join(tmp_dir, "archive.zip")
          File.write!(zip_path, body)
          System.cmd("unzip", ["-q", zip_path, "-d", tmp_dir])
          find_and_copy_binary(tmp_dir, binary, bin_path)

        true ->
          # Assume it's a raw binary
          File.write!(bin_path, body)
          File.chmod!(bin_path, 0o755)
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp find_and_copy_binary(dir, binary, dest) do
    # Find the binary in extracted directory
    case System.cmd("find", [dir, "-name", binary, "-type", "f"]) do
      {output, 0} ->
        source = output |> String.trim() |> String.split("\n") |> List.first()

        if source && source != "" do
          File.cp!(source, dest)
          File.chmod!(dest, 0o755)
        end

      _ ->
        :ok
    end
  end

  defp get_npm_version(package) do
    case System.cmd("npm", ["list", package, "--json"], cd: @noface_dir, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"dependencies" => deps}} ->
            get_in(deps, [package, "version"]) || "unknown"

          _ ->
            "unknown"
        end

      _ ->
        "unknown"
    end
  end

  defp update_version(tool, version) do
    current = versions()
    updated = Map.put(current, to_string(tool), version)
    File.write!(@versions_file, Jason.encode!(updated, pretty: true))
  end

  defp check_tool_update(name, %{type: :npm} = spec, current) do
    current_version = Map.get(current, to_string(name), "0.0.0")

    case System.cmd("npm", ["view", spec.package, "version"], stderr_to_stdout: true) do
      {latest, 0} ->
        latest = String.trim(latest)

        if latest != current_version do
          {:update_available, current_version, latest}
        else
          :up_to_date
        end

      {output, code} ->
        {:error, {:npm_check_failed, code, output}}
    end
  end

  defp check_tool_update(name, %{type: :binary} = spec, current) do
    current_version = Map.get(current, to_string(name), "v0.0.0")
    api_url = "https://api.github.com/repos/#{spec.repo}/releases/latest"

    case Req.get(api_url, headers: [{"accept", "application/vnd.github.v3+json"}]) do
      {:ok, %{status: 200, body: release}} ->
        latest = release["tag_name"]

        if latest != current_version do
          {:update_available, current_version, latest}
        else
          :up_to_date
        end

      {:ok, %{status: status}} ->
        {:error, {:github_api_error, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end
end

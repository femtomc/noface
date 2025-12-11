defmodule Mix.Tasks.Noface.Init do
  @moduledoc """
  Initialize noface in the current directory.

  ## Usage

      mix noface.init [--force]

  Options:
    --force   Reinstall tools even if already installed

  This will:
  1. Create `.noface/` directory structure
  2. Install local CLI tools (claude, codex, bd, gh, jj)
  3. Create default `.noface.toml` config if not present

  Tools are installed to `.noface/bin/` and `.noface/node_modules/`.
  This gives noface control over tool versions and enables auto-updates.
  """
  use Mix.Task

  @shortdoc "Initialize noface and install tools"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean])
    force = opts[:force] || false

    Mix.shell().info("Initializing noface...")

    # Ensure application dependencies are available
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    # Initialize tools
    case Noface.Tools.init(force: force) do
      :ok ->
        Mix.shell().info("")
        Mix.shell().info("Tools installed to .noface/bin/")

        # Show installed versions
        versions = Noface.Tools.versions()

        if map_size(versions) > 0 do
          Mix.shell().info("")
          Mix.shell().info("Installed versions:")

          Enum.each(versions, fn {tool, version} ->
            Mix.shell().info("  #{tool}: #{version}")
          end)
        end

        # Create default config if not present
        create_default_config()

        Mix.shell().info("")
        Mix.shell().info("Done! Run `mix noface.start --open` to start the server.")

      {:error, reason} ->
        Mix.shell().error("Initialization failed: #{inspect(reason)}")
    end
  end

  defp create_default_config do
    config_path = ".noface.toml"

    unless File.exists?(config_path) do
      project_name =
        File.cwd!()
        |> Path.basename()
        |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

      config = """
      # Noface configuration
      # See: https://github.com/femtomc/noface

      [project]
      name = "#{project_name}"
      build = "mix compile"
      test = "mix test"

      [agents]
      implementer = "claude"
      reviewer = "codex"
      timeout_seconds = 900
      num_workers = 3

      [passes]
      planner_enabled = true
      planner_interval = 5
      planner_mode = "event_driven"
      quality_enabled = true
      quality_interval = 10

      [tracker]
      type = "beads"
      sync_to_github = false

      # [monowiki]
      # vault = "wiki/vault"
      """

      File.write!(config_path, config)
      Mix.shell().info("Created #{config_path}")
    end
  end
end

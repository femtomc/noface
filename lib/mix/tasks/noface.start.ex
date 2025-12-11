defmodule Mix.Tasks.Noface.Start do
  @moduledoc """
  Start the noface server.

  ## Usage

      mix noface.start [--config PATH] [--open] [--run]

  Options:
    --config PATH   Path to .noface.toml config file (default: .noface.toml)
    --open          Open the dashboard in your browser automatically
    --run           Start in running mode (default is paused)

  The server starts PAUSED by default. Use the dashboard or API to resume.
  This gives you control over when the agents start working.

  Control the loop via dashboard buttons or API:
    - Noface.Core.Loop.step()           # Run one iteration
    - Noface.Core.Loop.get_loop_state() # Inspect state
    - Noface.Core.Loop.resume()         # Run continuously
    - Noface.Core.Loop.pause()          # Pause execution
  """
  use Mix.Task

  @shortdoc "Start the noface server"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [config: :string, open: :boolean, run: :boolean])

    config_path = opts[:config] || ".noface.toml"
    open_browser? = opts[:open] || false
    # Default to paused mode - user must explicitly use --run to start running
    start_paused? = not (opts[:run] || false)

    Mix.shell().info("Starting noface server...")

    # Start the application
    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    # Open browser if requested (after small delay for server to be ready)
    if open_browser? do
      Task.start(fn ->
        Process.sleep(1000)
        open_browser("http://localhost:4000")
      end)
    end

    # Load config and start the loop
    case Noface.Core.Config.load(config_path) do
      {:ok, config} ->
        start_fn =
          if start_paused?, do: &Noface.Core.Loop.start_paused/1, else: &Noface.Core.Loop.start/1

        case start_fn.(config) do
          :ok ->
            Mix.shell().info("")
            Mix.shell().info("Noface server started for #{config.project_name}")
            Mix.shell().info("Dashboard: http://localhost:4000")

            if start_paused? do
              Mix.shell().info("")
              Mix.shell().info("Loop is PAUSED. Click Resume in dashboard or use API:")
              Mix.shell().info("  Noface.Core.Loop.resume()  # Run continuously")
              Mix.shell().info("  Noface.Core.Loop.step()    # Run one iteration")
            else
              Mix.shell().info("")
              Mix.shell().info("Loop is RUNNING.")
            end

            # Keep running
            Process.sleep(:infinity)

          {:error, reason} ->
            Mix.shell().error("Failed to start: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Failed to load config: #{inspect(reason)}")
    end
  end

  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
    end
  end
end

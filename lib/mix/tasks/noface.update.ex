defmodule Mix.Tasks.Noface.Update do
  @moduledoc """
  Update CLI tools to their latest versions.

  ## Usage

      mix noface.update [TOOL]

  Examples:
      mix noface.update         # Check and update all tools
      mix noface.update claude  # Update only claude
      mix noface.update --check # Just check, don't update

  Options:
    --check   Only check for updates, don't install them
  """
  use Mix.Task

  @shortdoc "Update CLI tools"

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [check: :boolean])
    check_only = opts[:check] || false

    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    case rest do
      [] ->
        # Update all
        Mix.shell().info("Checking for updates...")

        case Noface.Tools.check_updates() do
          {:ok, updates} when map_size(updates) == 0 ->
            Mix.shell().info("All tools are up to date!")

          {:ok, updates} ->
            Mix.shell().info("Updates available:")

            Enum.each(updates, fn {tool, info} ->
              Mix.shell().info("  #{tool}: #{info.current} -> #{info.latest}")
            end)

            unless check_only do
              Mix.shell().info("")
              Mix.shell().info("Installing updates...")
              Noface.Tools.update_all()
              Mix.shell().info("Done!")
            end

          {:ok, updates, errors} ->
            # Partial success - show updates and warn about errors
            Enum.each(errors, fn {tool, reason} ->
              Mix.shell().error("Warning: Failed to check #{tool}: #{inspect(reason)}")
            end)

            if map_size(updates) == 0 do
              Mix.shell().info("No updates found (some checks failed)")
            else
              Mix.shell().info("Updates available:")

              Enum.each(updates, fn {tool, info} ->
                Mix.shell().info("  #{tool}: #{info.current} -> #{info.latest}")
              end)

              unless check_only do
                Mix.shell().info("")
                Mix.shell().info("Installing updates...")
                Noface.Tools.update_all()
                Mix.shell().info("Done!")
              end
            end
        end

      [tool | _] ->
        tool_atom = String.to_atom(tool)

        if check_only do
          Mix.shell().info("Checking #{tool}...")

          case Noface.Tools.check_updates() do
            {:ok, updates} ->
              case Map.get(updates, tool_atom) || Map.get(updates, tool) do
                nil ->
                  Mix.shell().info("#{tool} is up to date")

                info ->
                  Mix.shell().info("#{tool}: #{info.current} -> #{info.latest}")
              end

            {:ok, updates, errors} ->
              # Check if this specific tool had an error
              case Enum.find(errors, fn {t, _} -> t == tool_atom end) do
                {_, reason} ->
                  Mix.shell().error("Failed to check #{tool}: #{inspect(reason)}")

                nil ->
                  case Map.get(updates, tool_atom) || Map.get(updates, tool) do
                    nil ->
                      Mix.shell().info("#{tool} is up to date")

                    info ->
                      Mix.shell().info("#{tool}: #{info.current} -> #{info.latest}")
                  end
              end
          end
        else
          Mix.shell().info("Updating #{tool}...")

          case Noface.Tools.update(tool_atom) do
            :ok ->
              Mix.shell().info("#{tool} updated!")

            {:error, reason} ->
              Mix.shell().error("Failed: #{inspect(reason)}")
          end
        end
    end
  end
end

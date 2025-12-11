defmodule Mix.Tasks.Noface.Issue do
  @moduledoc """
  File a new issue via beads.

  ## Usage

      mix noface.issue "Issue title" [--body BODY] [--labels LABELS]

  Options:
    --body BODY      Issue description
    --labels LABELS  Comma-separated labels

  The issue will be added to the beads backlog and picked up by the loop.
  """
  use Mix.Task

  @shortdoc "File a new issue"

  @impl Mix.Task
  def run(args) do
    {opts, rest, _} = OptionParser.parse(args, strict: [body: :string, labels: :string])

    title =
      case rest do
        [t | _] -> t
        [] -> Mix.raise("Usage: mix noface.issue \"Issue title\" [--body BODY]")
      end

    {:ok, _} = Application.ensure_all_started(:noface_elixir)

    labels =
      if opts[:labels] do
        String.split(opts[:labels], ",") |> Enum.map(&String.trim/1)
      else
        nil
      end

    case Noface.Server.Command.file_issue(title, body: opts[:body], labels: labels) do
      {:ok, issue_id} ->
        Mix.shell().info("Created issue: #{issue_id}")

      {:error, reason} ->
        Mix.shell().error("Failed to create issue: #{reason}")
    end
  end
end

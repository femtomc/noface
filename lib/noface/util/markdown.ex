defmodule Noface.Util.Markdown do
  @moduledoc """
  Simple markdown rendering for terminal output.

  Provides basic markdown rendering with ANSI styling.
  Handles headers, bold, italic, code blocks, and lists.
  """

  # ANSI color codes
  @reset "\e[0m"
  @bold "\e[1m"
  @italic "\e[3m"
  @dim "\e[2m"
  @cyan "\e[0;36m"
  @yellow "\e[0;33m"
  @green "\e[0;32m"
  @magenta "\e[0;35m"

  @doc """
  Render markdown text to terminal with ANSI styling.
  """
  @spec render(String.t()) :: String.t()
  def render(input) do
    input
    |> String.split("\n")
    |> render_lines(false, [])
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @doc """
  Print rendered markdown directly to stdout.
  """
  @spec print(String.t()) :: :ok
  def print(input) do
    input
    |> render()
    |> IO.puts()
  end

  # Process lines, tracking code block state
  defp render_lines([], _in_code_block, acc), do: acc

  defp render_lines([line | rest], in_code_block, acc) do
    cond do
      # Code block fence
      String.starts_with?(line, "```") ->
        if in_code_block do
          render_lines(rest, false, [@reset | acc])
        else
          render_lines(rest, true, [@dim | acc])
        end

      # Inside code block
      in_code_block ->
        render_lines(rest, true, ["  " <> line | acc])

      # Headers
      String.starts_with?(line, "### ") ->
        content = String.slice(line, 4..-1//1)
        render_lines(rest, false, ["#{@yellow}#{@bold}#{content}#{@reset}" | acc])

      String.starts_with?(line, "## ") ->
        content = String.slice(line, 3..-1//1)
        render_lines(rest, false, ["#{@cyan}#{@bold}#{content}#{@reset}" | acc])

      String.starts_with?(line, "# ") ->
        content = String.slice(line, 2..-1//1)
        render_lines(rest, false, ["#{@magenta}#{@bold}#{content}#{@reset}" | acc])

      # Bullet lists
      String.starts_with?(line, "- ") or String.starts_with?(line, "* ") ->
        content = String.slice(line, 2..-1//1) |> render_inline()
        render_lines(rest, false, ["#{@green}• #{@reset}#{content}" | acc])

      # Numbered lists
      Regex.match?(~r/^\d+\. /, line) ->
        case Regex.run(~r/^(\d+)\. (.*)$/, line) do
          [_, num, content] ->
            rendered = render_inline(content)
            render_lines(rest, false, ["#{@green}#{num}. #{@reset}#{rendered}" | acc])

          _ ->
            render_lines(rest, false, [render_inline(line) | acc])
        end

      # Regular line
      true ->
        render_lines(rest, false, [render_inline(line) | acc])
    end
  end

  # Render inline elements (bold, italic, code)
  defp render_inline(text) do
    text
    |> render_bold()
    |> render_inline_code()
    |> render_italic()
  end

  defp render_bold(text) do
    Regex.replace(~r/\*\*(.+?)\*\*/, text, "#{@bold}\\1#{@reset}")
  end

  defp render_inline_code(text) do
    Regex.replace(~r/`(.+?)`/, text, "#{@dim}\\1#{@reset}")
  end

  defp render_italic(text) do
    # Match single * but not ** (already processed)
    Regex.replace(~r/(?<!\*)\*([^*]+?)\*(?!\*)/, text, "#{@italic}\\1#{@reset}")
  end
end

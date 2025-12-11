defmodule NofaceWeb.VaultLive do
  @moduledoc """
  Lightweight monowiki vault editor.

  Allows browsing, editing, and appending issue references to vault notes.
  Uses the configured monowiki vault path from .noface.toml.
  """
  use NofaceWeb, :live_view

  alias Noface.Core.Config

  @impl true
  def mount(_params, _session, socket) do
    config = load_config()

    vault =
      Application.get_env(:noface_elixir, :monowiki_vault) ||
        config.monowiki_vault

    # Only use vault if it's a valid, existing directory
    vault = if vault && File.dir?(vault), do: Path.expand(vault), else: nil

    {:ok,
     socket
     |> assign(
       vault: vault,
       notes: list_notes(vault),
       selected: nil,
       content: nil,
       status: nil
     )}
  end

  @impl true
  def handle_event("select", %{"slug" => slug}, socket) do
    case validate_slug(slug) do
      {:ok, safe_slug} ->
        {:noreply,
         assign(socket,
           selected: safe_slug,
           content: read_note(socket.assigns.vault, safe_slug),
           status: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, status: {:error, reason})}
    end
  end

  def handle_event("save", %{"slug" => slug, "content" => content}, socket) do
    with {:ok, safe_slug} <- validate_slug(slug),
         :ok <- write_note(socket.assigns.vault, safe_slug, content) do
      {:noreply,
       assign(socket,
         status: {:ok, "Saved #{safe_slug}"},
         notes: list_notes(socket.assigns.vault)
       )}
    else
      {:error, reason} when is_binary(reason) ->
        {:noreply, assign(socket, status: {:error, reason})}

      {:error, reason} ->
        {:noreply, assign(socket, status: {:error, inspect(reason)})}
    end
  end

  def handle_event("new", %{"slug" => slug}, socket) do
    slug = String.trim(slug || "")

    with {:ok, safe_slug} <- validate_slug(slug),
         false <- note_exists?(socket.assigns.vault, safe_slug) do
      :ok = write_note(socket.assigns.vault, safe_slug, "# #{safe_slug}\n")

      {:noreply,
       assign(socket,
         notes: list_notes(socket.assigns.vault),
         selected: safe_slug,
         content: read_note(socket.assigns.vault, safe_slug),
         status: {:ok, "Created #{safe_slug}"}
       )}
    else
      {:error, reason} ->
        {:noreply, assign(socket, status: {:error, reason})}

      true ->
        {:noreply, assign(socket, status: {:error, "Already exists"})}
    end
  end

  def handle_event(
        "append_issue",
        %{"slug" => slug, "issue_id" => issue_id, "note" => note},
        socket
      ) do
    issue_id = String.trim(issue_id || "")
    note_text = String.trim(note || "")

    with {:ok, safe_slug} <- validate_slug(slug) do
      content = read_note(socket.assigns.vault, safe_slug) || ""
      addition = "\n\n## Issues\n- #{issue_id} #{note_text}\n"

      case write_note(socket.assigns.vault, safe_slug, content <> addition) do
        :ok ->
          {:noreply, assign(socket, content: content <> addition, status: {:ok, "Linked issue"})}

        {:error, reason} ->
          {:noreply, assign(socket, status: {:error, inspect(reason)})}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, status: {:error, reason})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container" style="display: grid; grid-template-columns: 1fr 2fr; gap: 1ch; padding: 1ch;">
      <div class="card">
        <h2>Vault</h2>
        <%= if @vault do %>
          <div style="font-size: 0.85rem; color: var(--text-muted); margin-bottom: 0.5ch;">
            <code><%= @vault %></code>
          </div>
          <form phx-submit="new" style="display: flex; gap: 0.5ch; margin-bottom: 1ch;">
            <input name="slug" placeholder="new-note-slug" style="flex: 1;" />
            <button class="btn">New</button>
          </form>
          <div class="panel-content" style="max-height: 70vh; overflow-y: auto; padding: 0;">
            <div class="issue-list">
              <%= for slug <- @notes do %>
                <div class="issue" phx-click="select" phx-value-slug={slug}>
                  <div class="issue-header">
                    <span class="issue-id"><%= slug %></span>
                  </div>
                </div>
              <% end %>
              <%= if @notes == [] do %>
                <div class="empty-state">No notes found</div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="empty-state">Configure monowiki_vault in .noface.toml to enable vault editing.</div>
        <% end %>
      </div>

      <div class="card">
        <h2>Editor</h2>
        <%= if @selected && @content do %>
          <form phx-submit="save">
            <input type="hidden" name="slug" value={@selected} />
            <textarea name="content" style="width: 100%; min-height: 60vh; background: transparent; color: var(--text); border: 1px solid var(--border); padding: 0.5ch; font-family: var(--font-family);"><%= @content %></textarea>
            <div style="display: flex; gap: 0.5ch; margin-top: 0.5ch; align-items: center;">
              <button class="btn-primary" type="submit">Save</button>
              <span style="font-size: 0.85rem; color: var(--text-muted);">Editing <%= @selected %></span>
            </div>
          </form>
          <form phx-submit="append_issue" style="margin-top: 1ch; display: flex; gap: 0.5ch; align-items: center;">
            <input type="hidden" name="slug" value={@selected} />
            <input name="issue_id" placeholder="issue id" style="width: 14ch;" />
            <input name="note" placeholder="note" style="flex: 1;" />
            <button class="btn" type="submit">Append Issue</button>
          </form>
        <% else %>
          <div class="empty-state">Select a note to edit</div>
        <% end %>

        <%= if @status do %>
          <div style={"margin-top: 0.5ch; font-size: 0.85rem; color: #{status_color(@status)};"}><%= status_message(@status) %></div>
        <% end %>
      </div>
    </div>
    """
  end

  defp load_config do
    case Config.load(".noface.toml") do
      {:ok, config} -> config
      _ -> %Config{}
    end
  end

  # Validates a slug is safe: not empty, no path traversal, no absolute paths
  defp validate_slug(nil), do: {:error, "Slug required"}
  defp validate_slug(""), do: {:error, "Slug required"}

  defp validate_slug(slug) do
    slug = String.trim(slug)

    cond do
      slug == "" ->
        {:error, "Slug required"}

      String.contains?(slug, "..") ->
        {:error, "Invalid slug"}

      String.starts_with?(slug, "/") ->
        {:error, "Invalid slug"}

      String.contains?(slug, "\0") ->
        {:error, "Invalid slug"}

      true ->
        {:ok, slug}
    end
  end

  # Validates the resolved path is within the vault directory
  defp safe_path?(vault, path) do
    expanded_vault = Path.expand(vault)
    expanded_path = Path.expand(path)
    String.starts_with?(expanded_path, expanded_vault <> "/")
  end

  defp list_notes(nil), do: []

  defp list_notes(vault) do
    case File.ls(vault) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, [".md", ".markdown"]))
        |> Enum.map(&String.trim_trailing(&1, ".md"))
        |> Enum.map(&String.trim_trailing(&1, ".markdown"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp read_note(nil, _slug), do: nil

  defp read_note(vault, slug) do
    path = Path.join(vault, ensure_extension(slug))

    if safe_path?(vault, path) do
      case File.read(path) do
        {:ok, content} -> content
        _ -> nil
      end
    else
      nil
    end
  end

  defp write_note(nil, _slug, _content), do: {:error, :no_vault}

  defp write_note(vault, slug, content) do
    path = Path.join(vault, ensure_extension(slug))

    if safe_path?(vault, path) do
      File.write(path, content)
    else
      {:error, "Path escapes vault"}
    end
  end

  defp note_exists?(nil, _slug), do: false

  defp note_exists?(vault, slug) do
    path = Path.join(vault, ensure_extension(slug))
    safe_path?(vault, path) && File.exists?(path)
  end

  defp ensure_extension(slug) do
    if String.ends_with?(slug, [".md", ".markdown"]) do
      slug
    else
      slug <> ".md"
    end
  end

  defp status_message({:ok, msg}), do: msg
  defp status_message({:error, msg}), do: msg
  defp status_color({:ok, _}), do: "var(--success)"
  defp status_color({:error, _}), do: "var(--danger)"
end

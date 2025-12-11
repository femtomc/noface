defmodule NofaceWeb.VaultLive do
  @moduledoc """
  Lightweight monowiki vault editor.

  Allows browsing, editing, and appending issue references to vault notes.
  Uses the configured monowiki vault path from .noface.toml.
  """
  use NofaceWeb, :live_view

  alias Noface.Core.Config

  @impl true
  def mount(params, _session, socket) do
    config = load_config()

    vault =
      params["vault"] || Application.get_env(:noface_elixir, :monowiki_vault) ||
        config.monowiki_vault

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
    {:noreply,
     assign(socket, selected: slug, content: read_note(socket.assigns.vault, slug), status: nil)}
  end

  def handle_event("save", %{"slug" => slug, "content" => content}, socket) do
    case write_note(socket.assigns.vault, slug, content) do
      :ok ->
        {:noreply,
         assign(socket, status: {:ok, "Saved #{slug}"}, notes: list_notes(socket.assigns.vault))}

      {:error, reason} ->
        {:noreply, assign(socket, status: {:error, inspect(reason)})}
    end
  end

  def handle_event("new", %{"slug" => slug}, socket) do
    slug = String.trim(slug || "")

    cond do
      slug == "" ->
        {:noreply, assign(socket, status: {:error, "Slug required"})}

      note_exists?(socket.assigns.vault, slug) ->
        {:noreply, assign(socket, status: {:error, "Already exists"})}

      true ->
        :ok = write_note(socket.assigns.vault, slug, "# #{slug}\n")

        {:noreply,
         assign(socket,
           notes: list_notes(socket.assigns.vault),
           selected: slug,
           content: read_note(socket.assigns.vault, slug),
           status: {:ok, "Created #{slug}"}
         )}
    end
  end

  def handle_event(
        "append_issue",
        %{"slug" => slug, "issue_id" => issue_id, "note" => note},
        socket
      ) do
    issue_id = String.trim(issue_id || "")
    note_text = String.trim(note || "")
    content = read_note(socket.assigns.vault, slug) || ""

    addition = "\n\n## Issues\n- #{issue_id} #{note_text}\n"

    case write_note(socket.assigns.vault, slug, content <> addition) do
      :ok ->
        {:noreply, assign(socket, content: content <> addition, status: {:ok, "Linked issue"})}

      {:error, reason} ->
        {:noreply, assign(socket, status: {:error, inspect(reason)})}
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

    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp write_note(nil, _slug, _content), do: {:error, :no_vault}

  defp write_note(vault, slug, content) do
    path = Path.join(vault, ensure_extension(slug))
    File.write(path, content)
  end

  defp note_exists?(nil, _slug), do: false
  defp note_exists?(vault, slug), do: File.exists?(Path.join(vault, ensure_extension(slug)))

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

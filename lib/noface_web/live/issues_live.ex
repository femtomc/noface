defmodule NofaceWeb.IssuesLive do
  @moduledoc """
  LiveView for browsing and managing issues.
  """
  use Phoenix.LiveView

  alias Noface.Core.State

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    {:ok, assign_issues(socket)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    issue = State.get_issue(id)
    {:noreply, assign(socket, selected_issue: issue, page_title: "Issue #{id}")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, selected_issue: nil, page_title: "Issues")}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_issues(socket)}
  end

  defp assign_issues(socket) do
    issues = State.list_issues()
    assign(socket, issues: issues)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="issues">
      <%= if @selected_issue do %>
        <.issue_detail issue={@selected_issue} />
      <% else %>
        <.issue_list issues={@issues} />
      <% end %>
    </div>
    """
  end

  defp issue_list(assigns) do
    ~H"""
    <div class="card">
      <h2>Issues (<%= length(@issues) %>)</h2>
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Status</th>
            <th>Attempts</th>
            <th>Worker</th>
          </tr>
        </thead>
        <tbody>
          <%= for issue <- @issues do %>
            <tr>
              <td>
                <a href={"/issues/#{issue.id}"} style="color: var(--accent); text-decoration: none;">
                  <%= issue.id %>
                </a>
              </td>
              <td>
                <span class={"status-badge status-#{issue.status}"}>
                  <%= issue.status %>
                </span>
              </td>
              <td><%= issue.attempt_count %></td>
              <td><%= issue.assigned_worker || "-" %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
      <%= if @issues == [] do %>
        <p style="color: var(--text-muted); text-align: center; padding: 2rem;">
          No issues yet. File one with <code>mix noface.issue "title"</code>
        </p>
      <% end %>
    </div>
    """
  end

  defp issue_detail(assigns) do
    ~H"""
    <div>
      <a href="/issues" style="color: var(--accent); text-decoration: none; margin-bottom: 1rem; display: inline-block;">
        &larr; Back to issues
      </a>
      <div class="card">
        <h2>Issue <%= @issue.id %></h2>
        <div style="margin-bottom: 1rem;">
          <span class={"status-badge status-#{@issue.status}"}>
            <%= @issue.status %>
          </span>
        </div>
        <table>
          <tr>
            <th style="width: 150px;">Attempts</th>
            <td><%= @issue.attempt_count %></td>
          </tr>
          <tr>
            <th>Assigned Worker</th>
            <td><%= @issue.assigned_worker || "None" %></td>
          </tr>
          <%= if @issue.manifest do %>
            <tr>
              <th>Primary Files</th>
              <td><%= Enum.join(@issue.manifest.primary_files || [], ", ") %></td>
            </tr>
          <% end %>
          <%= if @issue.last_attempt do %>
            <tr>
              <th>Last Attempt</th>
              <td>
                <%= @issue.last_attempt.result %>
                (<%= @issue.last_attempt.timestamp %>)
              </td>
            </tr>
          <% end %>
        </table>
      </div>
    </div>
    """
  end
end

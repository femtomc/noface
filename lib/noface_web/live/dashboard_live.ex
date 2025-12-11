defmodule NofaceWeb.DashboardLive do
  @moduledoc """
  Real-time dashboard for noface orchestrator.
  Redesigned to match the React viewer's two-panel layout.
  """
  use Phoenix.LiveView

  alias Noface.Server.Command
  alias Noface.Core.State
  alias Noface.Util.Transcript

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    socket =
      socket
      |> assign(
        filter: "all",
        expanded: nil,
        page_title: "Dashboard",
        left_tab: "issues",
        selected_session: nil
      )
      |> assign_data()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, assign(socket, filter: status)}
  end

  def handle_event("toggle_issue", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded == id, do: nil, else: id
    {:noreply, assign(socket, expanded: expanded)}
  end

  def handle_event("set_left_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, left_tab: tab)}
  end

  def handle_event("select_session", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_session: id)}
  end

  def handle_event("pause", _params, socket) do
    case Command.pause() do
      :ok -> {:noreply, assign_data(socket)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("resume", _params, socket) do
    case Command.resume() do
      :ok -> {:noreply, assign_data(socket)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("interrupt", _params, socket) do
    Command.interrupt()
    {:noreply, assign_data(socket)}
  end

  defp assign_data(socket) do
    status = Command.status()
    issues = get_issues()
    state_counts = status[:state] || %{}
    sessions = load_sessions()
    selected_session = pick_session(socket.assigns.selected_session, issues, sessions)

    stats = %{
      total: state_counts[:total_issues] || length(issues),
      open: state_counts[:pending] || Enum.count(issues, &(&1.status == :pending)),
      in_progress: state_counts[:in_progress] || Enum.count(issues, &(&1.status in [:assigned, :running])),
      closed: (state_counts[:completed] || 0) + (state_counts[:failed] || 0)
    }

    assign(socket,
      status: status,
      issues: issues,
      stats: stats,
      workers: get_workers(status),
      sessions: sessions,
      selected_session: selected_session
    )
  end

  defp get_issues do
    try do
      State.list_issues()
      |> Enum.map(&present_issue/1)
      |> Enum.sort_by(fn issue ->
        # In progress first, then by priority
        status_order = if issue.status in [:assigned, :running], do: 0, else: 1
        {status_order, issue.priority || 2, issue.id}
      end)
    rescue
      _ -> []
    end
  end

  defp get_workers(status) do
    case status do
      %{workers: %{workers: workers, num_workers: n}} ->
        Enum.take(workers || [], n || 0)
      %{workers: workers, num_workers: n} when is_list(workers) ->
        Enum.take(workers || [], n || 0)
      _ ->
        []
    end
  end

  defp filter_issues(issues, "all"), do: issues
  defp filter_issues(issues, "open"), do: Enum.filter(issues, &(&1.status == :pending))
  defp filter_issues(issues, "in_progress"), do: Enum.filter(issues, &(&1.status in [:assigned, :running]))
  defp filter_issues(issues, "closed"), do: Enum.filter(issues, &(&1.status in [:completed, :failed]))
  defp filter_issues(issues, _), do: issues

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .app-container {
        display: grid;
        grid-template-rows: auto 1fr;
        grid-template-columns: 1fr 1fr;
        gap: 1ch;
        height: calc(100vh - 60px);
        padding: 1ch;
      }
      .app-header {
        grid-column: 1 / -1;
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 0 1ch;
        border-bottom: var(--border-thickness) solid var(--border);
        padding-bottom: 0.5ch;
      }
      .app-header h1 {
        font-size: 1rem;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.1ch;
        display: flex;
        align-items: center;
        gap: 1ch;
      }
      .header-stats {
        display: flex;
        gap: 3ch;
        color: var(--text-muted);
        font-size: 0.85rem;
      }
      .header-stat {
        display: flex;
        gap: 0.5ch;
      }
      .header-stat-value {
        color: var(--text);
        font-weight: 500;
      }
      .live-indicator {
        display: inline-block;
        width: 10px;
        height: 10px;
        background: var(--success);
        border-radius: 50%;
        animation: pulse 2s infinite;
        margin-right: 0.5ch;
      }
      .live-dot {
        width: 8px;
        height: 8px;
        background: var(--success);
        border-radius: 50%;
        animation: pulse 2s infinite;
      }
      @keyframes pulse {
        0%, 100% { opacity: 1; }
        50% { opacity: 0.4; }
      }
      .panel {
        background: var(--bg-secondary);
        border: var(--border-thickness) solid var(--border);
        display: flex;
        flex-direction: column;
        overflow: hidden;
        min-height: 0;
      }
      .panel-header {
        padding: 0.5ch 1ch;
        border-bottom: var(--border-thickness) solid var(--border);
        font-weight: 700;
        text-transform: uppercase;
        font-size: 0.85rem;
        letter-spacing: 0.05ch;
        background: var(--bg-alt);
        display: flex;
        justify-content: space-between;
        align-items: center;
      }
      .panel-content {
        flex: 1;
        overflow-y: auto;
        padding: 1ch;
      }
      .tabs {
        display: flex;
        gap: 0;
        border-bottom: var(--border-thickness) solid var(--border);
        flex-wrap: wrap;
      }
      .tab {
        padding: 0.5ch 1.5ch;
        cursor: pointer;
        border: none;
        background: transparent;
        color: var(--text-muted);
        font: inherit;
        text-transform: uppercase;
        font-size: 0.85rem;
        border-bottom: var(--border-thickness) solid transparent;
        margin-bottom: calc(-1 * var(--border-thickness));
      }
      .tab:hover { color: var(--text); }
      .tab.active {
        color: var(--text);
        border-bottom-color: var(--accent);
      }
      .filter-bar {
        display: flex;
        gap: 0.5ch;
        padding: 0.5ch 1ch;
        border-bottom: 1px solid var(--border);
      }
      .filter-btn {
        padding: 0 1ch;
        border: 1px solid var(--border);
        background: transparent;
        color: var(--text-muted);
        font: inherit;
        font-size: 0.75rem;
        cursor: pointer;
        text-transform: uppercase;
      }
      .filter-btn:hover { border-color: var(--text-muted); color: var(--text); }
      .filter-btn.active { border-color: var(--accent); color: var(--accent); }
      .issue-list {
        display: flex;
        flex-direction: column;
        gap: 0.5ch;
      }
      .issue {
        padding: 0.5ch 1ch;
        border: 1px solid var(--border);
        cursor: pointer;
      }
      .issue:hover { border-color: var(--text-muted); }
      .issue-header {
        display: flex;
        gap: 1ch;
        align-items: flex-start;
      }
      .issue-id {
        color: var(--text-muted);
        font-size: 0.8rem;
        flex-shrink: 0;
      }
      .issue-title {
        flex: 1;
        font-weight: 500;
      }
      .issue-meta {
        display: flex;
        gap: 1ch;
        margin-top: 0.25ch;
        font-size: 0.75rem;
      }
      .priority {
        padding: 0 0.5ch;
        font-weight: 700;
        border: 1px solid currentColor;
      }
      .priority-0 { color: var(--danger); }
      .priority-1 { color: var(--warning); }
      .priority-2 { color: var(--accent); }
      .priority-3 { color: var(--text-dim); }
      .issue-status {
        text-transform: uppercase;
      }
      .issue-status.pending { color: var(--text-muted); }
      .issue-status.running, .issue-status.assigned { color: var(--warning); }
      .issue-status.completed { color: var(--success); }
      .issue-status.failed { color: var(--danger); }
      .issue-expanded {
        margin-top: 0.5ch;
        padding-top: 0.5ch;
        border-top: 1px solid var(--border);
        font-size: 0.85rem;
        color: var(--text-muted);
      }
      .worker-grid {
        display: flex;
        gap: 1ch;
        padding: 0.5ch 1ch;
        border-bottom: 1px solid var(--border);
        background: var(--bg-alt);
        flex-wrap: wrap;
      }
      .worker {
        font-size: 0.8rem;
      }
      .worker-id { color: var(--text-dim); }
      .worker-status { text-transform: uppercase; }
      .worker-status.idle { color: var(--text-dim); }
      .worker-status.running { color: var(--warning); }
      .worker-status.completed { color: var(--success); }
      .controls {
        display: flex;
        gap: 0.5ch;
        padding: 0.5ch 1ch;
        border-bottom: 1px solid var(--border);
      }
      .ctrl-btn {
        padding: 0.25ch 1ch;
        border: 1px solid var(--border);
        background: transparent;
        color: var(--text);
        font: inherit;
        font-size: 0.8rem;
        cursor: pointer;
        text-transform: uppercase;
      }
      .ctrl-btn:hover { border-color: var(--text-muted); }
      .ctrl-btn.primary { border-color: var(--accent); color: var(--accent); }
      .ctrl-btn.danger { border-color: var(--danger); color: var(--danger); }
      .progress-bar {
        font-family: inherit;
      }
      .progress-filled { color: var(--success); }
      .progress-empty { color: var(--text-dim); }
      .empty-state {
        color: var(--text-dim);
        text-align: center;
        padding: 2ch;
      }
      .agent-output {
        font-size: 0.85rem;
        line-height: 1.4;
        display: flex;
        flex-direction: column;
        gap: 0.5ch;
      }
      .tool-call {
        padding: 0.25ch 0;
        border-left: 2px solid var(--accent);
        padding-left: 1ch;
        color: var(--text-muted);
      }
      .tool-call-name {
        color: var(--accent);
        font-weight: 700;
      }
      .tool-call-params {
        color: var(--text-muted);
        font-size: 0.8rem;
      }
      .text-delta {
        white-space: pre-wrap;
        word-break: break-word;
        color: var(--text);
        font-family: var(--font-family);
      }
      .dep-graph {
        font-family: var(--font-family);
        font-size: 0.85rem;
        line-height: 1.4;
        margin: 0;
        white-space: pre;
      }
      .dep-prefix { color: var(--text-dim); }
      .dep-marker-success { color: var(--success); }
      .dep-marker-warning { color: var(--warning); }
      .dep-marker-idle { color: var(--text-dim); }
      .loop-info {
        padding: 1ch;
        font-size: 0.85rem;
        color: var(--text-muted);
      }
      .loop-info div { margin-bottom: 0.25ch; }
      .loop-info strong { color: var(--text); }
    </style>

    <div class="app-container">
      <header class="app-header">
        <h1>
          <%= if loop_running?(@status) do %><span class="live-indicator"></span><% end %>
          noface
        </h1>
        <div class="header-stats">
          <div class="header-stat">
            <span class="progress-bar">
              <span class="progress-filled"><%= progress_bar(@stats.closed, @stats.total) %></span>
            </span>
            <span class="header-stat-value"><%= @stats.closed %>/<%= @stats.total %></span>
          </div>
          <div class="header-stat">
            <span>open:</span>
            <span class="header-stat-value"><%= @stats.open %></span>
          </div>
          <div class="header-stat">
            <span style="color: var(--warning);">active:</span>
            <span class="header-stat-value"><%= @stats.in_progress %></span>
          </div>
          <div class="header-stat">
            <span>iter:</span>
            <span class="header-stat-value"><%= get_in(@status, [:loop, :iteration]) || 0 %></span>
          </div>
          <div class="header-stat">
            <span>workers:</span>
            <span class="header-stat-value">
              <%= Enum.count(@workers, &(&1.status == :running)) %>/<%= length(@workers) %>
            </span>
          </div>
        </div>
      </header>

      <!-- Left Panel: Issues / Dependency Graph -->
      <div class="panel">
        <div class="panel-header">
          <span><%= if @left_tab == "issues", do: "Issues", else: "Dependency Graph" %></span>
          <div style="display: flex; gap: 1ch; align-items: center; font-size: 0.8rem;">
            <%= if @left_tab == "issues" do %>
              <span style="color: var(--text-muted);"><%= length(filter_issues(@issues, @filter)) %> shown</span>
              <button class="filter-btn" phx-click="set_left_tab" phx-value-tab="graph">graph →</button>
            <% else %>
              <button class="filter-btn" phx-click="set_left_tab" phx-value-tab="issues">← issues</button>
            <% end %>
          </div>
        </div>
        <%= if @left_tab == "issues" do %>
          <div class="filter-bar">
            <%= for status <- ["all", "open", "in_progress", "closed"] do %>
              <button
                class={"filter-btn #{if @filter == status, do: "active"}"}
                phx-click="filter"
                phx-value-status={status}
              >
                <%= String.replace(status, "_", " ") %>
              </button>
            <% end %>
          </div>
          <div class="panel-content">
            <%= if filter_issues(@issues, @filter) == [] do %>
              <div class="empty-state">No issues</div>
            <% else %>
              <div class="issue-list">
                <%= for issue <- filter_issues(@issues, @filter) do %>
                  <div class="issue" phx-click="toggle_issue" phx-value-id={issue.id}>
                    <div class="issue-header">
                      <span class="issue-id"><%= issue.id %></span>
                      <span class="issue-title"><%= issue.title || "(no title)" %></span>
                    </div>
                    <div class="issue-meta">
                      <span class={"priority priority-#{issue.priority || 2}"}>
                        P<%= issue.priority || 2 %>
                      </span>
                      <span class={"issue-status #{issue.status}"}>
                        <%= issue.status %>
                      </span>
                      <%= if issue.issue_type do %>
                        <span style="color: var(--text-dim); text-transform: uppercase;">
                          <%= issue.issue_type %>
                        </span>
                      <% end %>
                      <%= if issue.dependencies && issue.dependencies != [] do %>
                        <span style="color: var(--text-dim); font-size: 0.75rem;">
                          blocks <%= Enum.count(issue.dependencies) %>
                        </span>
                      <% end %>
                    </div>
                    <%= if @expanded == issue.id do %>
                      <div class="issue-expanded">
                        <%= if issue.description do %>
                          <div style="margin-bottom: 0.5ch;"><%= issue.description %></div>
                        <% end %>
                        <%= if issue.acceptance_criteria do %>
                          <div style="border-top: 1px solid var(--border); padding-top: 0.5ch; margin-top: 0.5ch;">
                            <strong>Acceptance:</strong>
                            <div style="white-space: pre-wrap;"><%= issue.acceptance_criteria %></div>
                          </div>
                        <% end %>
                        <%= if issue.dependencies && issue.dependencies != [] do %>
                          <div style="border-top: 1px solid var(--border); padding-top: 0.5ch; margin-top: 0.5ch;">
                            <strong>Blocks:</strong>
                            <div style="white-space: pre-wrap;"><%= Enum.map(issue.dependencies, & &1.depends_on_id) |> Enum.join(", ") %></div>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="panel-content">
            <%= case dependency_lines(@issues) do %>
              <% [] -> %>
                <div class="empty-state">No dependency relationships</div>
              <% lines -> %>
                <pre class="dep-graph">
                  <%= for line <- lines do %>
                    <div>
                      <span class="dep-prefix"><%= line.prefix %></span>
                      <span style={"color: #{line.color}"}><%= line.marker %></span>
                      <span><%= line.text %></span>
                    </div>
                  <% end %>
                </pre>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Right Panel: Agent Activity -->
      <div class="panel">
        <div class="panel-header">
          <span>Agent Activity</span>
          <div style="font-weight: normal; font-size: 0.75rem; display: flex; gap: 2ch;">
            <span>done: <strong><%= get_in(@status, [:state, :completed]) || 0 %></strong></span>
            <span>failed: <strong><%= get_in(@status, [:state, :failed]) || 0 %></strong></span>
          </div>
        </div>

        <%= if @workers != [] do %>
          <div class="worker-grid" style={"grid-template-columns: repeat(#{max(length(@workers), 1)}, minmax(12ch, 1fr));"}>
            <%= for worker <- @workers do %>
              <div class="worker">
                <span class="worker-id">W<%= worker.id %></span>
                <span class={"worker-status #{worker.status}"}><%= worker.status %></span>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="controls">
          <%= if loop_running?(@status) and not loop_paused?(@status) do %>
            <button class="ctrl-btn" phx-click="pause">Pause</button>
            <button class="ctrl-btn danger" phx-click="interrupt">Interrupt</button>
          <% else %>
            <button class="ctrl-btn primary" phx-click="resume">Resume</button>
          <% end %>
        </div>

        <div class="panel-content">
          <div class="loop-info">
            <div>
              <strong>Status:</strong>
              <%= cond do %>
                <% loop_paused?(@status) -> %>
                  <span style="color: var(--warning);">PAUSED</span>
                <% loop_running?(@status) -> %>
                  <span style="color: var(--success);">RUNNING</span>
                <% true -> %>
                  <span style="color: var(--text-dim);">IDLE</span>
              <% end %>
            </div>
            <div>
              <strong>Iteration:</strong> <%= get_in(@status, [:loop, :iteration]) || 0 %>
            </div>
            <div>
              <strong>Current:</strong>
              <%= case get_in(@status, [:loop, :current_work]) do %>
                <% nil -> %>idle
                <% :busy -> %>working...
                <% work -> %><%= inspect(work) %>
              <% end %>
            </div>
            <div>
              <strong>Uptime:</strong> <%= format_uptime(get_in(@status, [:server, :uptime_seconds]) || 0) %>
            </div>
          </div>

          <div class="tabs" style="margin: 0 1ch;">
            <%= if map_size(@sessions) == 0 do %>
              <span class="empty-state" style="padding: 0.5ch 0; width: 100%;">No sessions yet</span>
            <% else %>
              <%= for id <- session_order(@sessions, active_issue_id(@issues)) do %>
                <button
                  class={"tab #{if @selected_session == id, do: "active"}"}
                  phx-click="select_session"
                  phx-value-id={id}
                >
                  <%= if active_issue_id(@issues) == id do %><span class="live-indicator"></span><% end %>
                  <%= id %>
                </button>
              <% end %>
            <% end %>
          </div>

          <% events = session_events(assigns) %>
          <%= cond do %>
            <% map_size(@sessions) == 0 -> %>
              <div class="empty-state">Agent sessions will appear here when work starts.</div>
            <% is_nil(@selected_session) -> %>
              <div class="empty-state">Select a session to view agent activity</div>
            <% events == [] -> %>
              <div class="empty-state">No activity yet</div>
            <% true -> %>
              <div class="agent-output">
                <%= for event <- events do %>
                  <%= render_event(event) %>
                <% end %>
              </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp loop_running?(status), do: get_in(status, [:loop, :running]) == true
  defp loop_paused?(status), do: get_in(status, [:loop, :paused]) == true

  defp progress_bar(_done, total) when total == 0, do: String.duplicate("░", 12)
  defp progress_bar(done, total) do
    width = 12
    filled = round(done / total * width)
    String.duplicate("█", filled) <> String.duplicate("░", width - filled)
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp present_issue(%{id: id} = issue) do
    content = issue.content || %{}

    status =
      cond do
        issue.status -> issue.status
        value = fetch_field(content, "status") -> normalize_status(value)
        true -> :pending
      end

    %{
      id: id,
      title: fetch_field(content, "title") || "(no title)",
      description: fetch_field(content, "description"),
      acceptance_criteria: fetch_field(content, "acceptance_criteria"),
      priority: normalize_priority(fetch_field(content, "priority")),
      issue_type: fetch_field(content, "issue_type"),
      status: status,
      dependencies: fetch_field(content, "dependencies") || [],
      attempt_count: issue.attempt_count,
      assigned_worker: issue.assigned_worker,
      manifest: issue.manifest,
      last_attempt: issue.last_attempt
    }
  end

  defp fetch_field(content, key) do
    Map.get(content, key) ||
      Map.get(content, to_string(key)) ||
      case maybe_existing_atom(key) do
        nil -> nil
        atom_key -> Map.get(content, atom_key)
      end
  rescue
    _ -> nil
  end

  defp maybe_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      _ -> nil
    end
  end

  defp maybe_existing_atom(key) when is_atom(key), do: key
  defp maybe_existing_atom(_), do: nil

  defp normalize_priority(nil), do: 2
  defp normalize_priority(priority) when is_binary(priority) do
    case Integer.parse(priority) do
      {int, _} -> normalize_priority(int)
      :error -> 2
    end
  end

  defp normalize_priority(priority) when is_integer(priority) and priority >= 0, do: priority
  defp normalize_priority(_), do: 2

  defp normalize_status(status) when is_binary(status) do
    case String.downcase(status) do
      "open" -> :pending
      "in_progress" -> :running
      "closed" -> :completed
      _ -> :pending
    end
  end

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_), do: :pending

  defp load_sessions do
    try do
      Transcript.recent_sessions(10)
      |> Enum.reduce(%{}, fn session, acc ->
        case Transcript.get_events(session.id) do
          {:ok, events} ->
            mapped = Enum.map(events, &present_event/1)
            Map.update(acc, session.issue_id, mapped, &(&1 ++ mapped))

          _ ->
            acc
        end
      end)
    rescue
      _ -> %{}
    end
  end

  defp present_event(event) do
    %{
      type: normalize_event_type(event.event_type),
      name: event.tool_name,
      input: decode_raw(event.raw_json),
      content: event.content
    }
  end

  defp normalize_event_type("tool"), do: :tool
  defp normalize_event_type("text"), do: :text
  defp normalize_event_type(_), do: :text

  defp decode_raw(nil), do: nil

  defp decode_raw(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, val} -> val
      _ -> raw
    end
  rescue
    _ -> raw
  end

  defp decode_raw(raw), do: raw

  defp pick_session(current, issues, sessions) do
    cond do
      current && Map.has_key?(sessions, current) ->
        current

      active = active_issue_id(issues) ->
        if Map.has_key?(sessions, active), do: active, else: Map.keys(sessions) |> List.first()

      true ->
        Map.keys(sessions) |> List.first()
    end
  end

  defp session_order(sessions, active_issue_id) do
    ids = Map.keys(sessions)

    Enum.sort(ids, fn a, b ->
      cond do
        a == active_issue_id and b != active_issue_id -> true
        b == active_issue_id and a != active_issue_id -> false
        true -> a <= b
      end
    end)
  end

  defp active_issue_id(issues) do
    case Enum.find(issues, &(&1.status in [:assigned, :running])) do
      nil -> nil
      issue -> issue.id
    end
  end

  defp session_events(assigns) do
    Map.get(assigns.sessions || %{}, assigns.selected_session, [])
  end

  defp render_event(%{type: :tool} = event) do
    assigns = %{event: event, params: format_tool_params(event.name, event.input)}

    ~H"""
    <div class="tool-call">
      <span class="tool-call-name">[<%= @event.name || "tool" %>]</span>
      <%= if @params do %>
        <span class="tool-call-params"> <%= @params %></span>
      <% end %>
    </div>
    """
  end

  defp render_event(%{type: :text} = event) do
    assigns = %{event: event}

    ~H"""
    <pre class="text-delta"><%= truncate_text(@event.content || "", 500) %></pre>
    """
  end

  defp render_event(_), do: nil

  defp format_tool_params(_name, nil), do: nil

  defp format_tool_params(name, input) when is_map(input) do
    case name do
      "Read" -> Map.get(input, "file_path") || Map.get(input, :file_path)
      "Write" -> Map.get(input, "file_path") || Map.get(input, :file_path)
      "Edit" -> Map.get(input, "file_path") || Map.get(input, :file_path)
      "Bash" ->
        cmd = Map.get(input, "command") || Map.get(input, :command) || ""
        if is_binary(cmd) and String.length(cmd) > 60, do: String.slice(cmd, 0, 60) <> "...", else: cmd

      "Grep" ->
        pattern = Map.get(input, "pattern") || Map.get(input, :pattern) || ""
        path = Map.get(input, "path") || Map.get(input, :path) || ""
        "\"#{pattern}\" #{path}"

      "Glob" ->
        pattern = Map.get(input, "pattern") || Map.get(input, :pattern) || ""
        "\"#{pattern}\""

      "Task" ->
        Map.get(input, "description") || Map.get(input, :description)

      _ ->
        nil
    end
  end

  defp format_tool_params(_name, input), do: input

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "...", else: text
  end

  defp truncate_text(text, _), do: text

  defp dependency_lines(issues) do
    issue_map = Map.new(issues, &{&1.id, &1})

    {blocks, blocked_by} =
      Enum.reduce(issues, {%{}, %{}}, fn issue, {bacc, bbacc} ->
        deps = issue.dependencies || []

        Enum.reduce(deps, {bacc, bbacc}, fn dep, {b, bb} ->
          child = Map.get(dep, :issue_id) || Map.get(dep, "issue_id") || issue.id
          blocker = Map.get(dep, :depends_on_id) || Map.get(dep, "depends_on_id")

          b =
            if blocker do
              Map.update(b, blocker, [child], &[child | &1])
            else
              b
            end

          bb =
            if blocker do
              Map.update(bb, child, [blocker], &[blocker | &1])
            else
              bb
            end

          {b, bb}
        end)
      end)

    roots =
      issues
      |> Enum.filter(fn issue ->
        deps = Map.get(blocked_by, issue.id, [])

        deps == [] or
          Enum.all?(deps, fn dep_id ->
            case Map.get(issue_map, dep_id) do
              %{status: status} -> status in [:completed, :failed]
              _ -> true
            end
          end)
      end)
      |> Enum.sort_by(&(&1.priority || 2))

    roots
    |> Enum.with_index()
    |> Enum.flat_map(fn {issue, idx} ->
      render_tree(issue.id, issue_map, blocks, MapSet.new(), "", idx == length(roots) - 1)
    end)
  end

  defp render_tree(issue_id, issue_map, blocks, visited, prefix, is_last) do
    if MapSet.member?(visited, issue_id) do
      []
    else
      visited = MapSet.put(visited, issue_id)
      issue = Map.get(issue_map, issue_id)
      {marker, color} = status_marker(issue && issue.status)
      connector = if is_last, do: "└─", else: "├─"
      title = if issue && issue.title, do: " #{issue.title}", else: ""
      line = %{prefix: prefix <> connector <> " ", marker: marker, color: color, text: "#{issue_id}#{title}"}

      children = Map.get(blocks, issue_id, []) |> Enum.reverse()
      child_prefix = prefix <> if is_last, do: "   ", else: "│  "

      child_lines =
        children
        |> Enum.with_index()
        |> Enum.flat_map(fn {child_id, idx} ->
          render_tree(child_id, issue_map, blocks, visited, child_prefix, idx == length(children) - 1)
        end)

      [line | child_lines]
    end
  end

  defp status_marker(status) do
    case status do
      :completed -> {"✓", "var(--success)"}
      :running -> {"▶", "var(--warning)"}
      :assigned -> {"▶", "var(--warning)"}
      :failed -> {"✗", "var(--danger)"}
      :pending -> {"○", "var(--text-dim)"}
      _ -> {"○", "var(--text-dim)"}
    end
  end
end

defmodule NofaceWeb.DashboardLive do
  @moduledoc """
  Real-time dashboard for noface orchestrator.
  Redesigned to match the React viewer's two-panel layout.
  """
  use NofaceWeb, :live_view

  alias Noface.Server.Command
  alias Noface.Core.State
  alias Noface.Transcript
  alias Phoenix.PubSub

  @impl true
  def mount(_params, session, socket) do
    test_state = Map.get(session, "test_state") || Map.get(session, :test_state)

    if connected?(socket) and is_nil(test_state) do
      PubSub.subscribe(Noface.PubSub, "state")
      PubSub.subscribe(Noface.PubSub, "loop")
      PubSub.subscribe(Noface.PubSub, "session")
    end

    socket =
      socket
      |> assign(
        filter: "all",
        expanded: nil,
        page_title: "Dashboard",
        left_tab: "issues",
        selected_session: nil,
        test_state: test_state
      )
      |> assign_data()

    {:ok, socket}
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

  def handle_event(
        "add_comment",
        %{"id" => id, "comment" => %{"body" => body} = params},
        %{assigns: %{test_state: test_state}} = socket
      )
      when is_map(test_state) do
    body = String.trim(body || "")
    author = String.trim(params["author"] || "user")

    updated_state =
      if body == "" do
        test_state
      else
        add_comment_to_test_state(test_state, id, author, body)
      end

    {:noreply, socket |> assign(test_state: updated_state) |> assign_data()}
  end

  def handle_event("add_comment", %{"id" => id, "comment" => %{"body" => body} = params}, socket) do
    body = String.trim(body || "")
    author = String.trim(params["author"] || "user")

    if body != "" do
      Command.comment_issue(id, author, body)
    end

    {:noreply, assign_data(socket)}
  end

  def handle_event(
        "update_issue",
        %{"id" => id, "issue" => attrs},
        %{assigns: %{test_state: test_state}} = socket
      )
      when is_map(test_state) do
    updated_state = update_test_issue_content(test_state, id, attrs)
    {:noreply, socket |> assign(test_state: updated_state) |> assign_data()}
  end

  def handle_event("update_issue", %{"id" => id, "issue" => attrs}, socket) do
    Command.update_issue(id, attrs)
    {:noreply, assign_data(socket)}
  end

  def handle_event("pause", _params, socket) do
    case Command.pause() do
      :ok ->
        {:noreply, socket |> clear_flash() |> assign_data()}

      {:error, :already_paused} ->
        {:noreply, socket |> put_flash(:info, "Loop is already paused")}

      {:error, :not_running} ->
        {:noreply, socket |> put_flash(:error, "Loop is not running")}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Pause failed: #{inspect(reason)}")}
    end
  end

  def handle_event("resume", _params, socket) do
    case Command.resume() do
      :ok ->
        {:noreply, socket |> clear_flash() |> assign_data()}

      {:error, :not_paused} ->
        {:noreply, socket |> put_flash(:info, "Loop is not paused")}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Resume failed: #{inspect(reason)}")}
    end
  end

  def handle_event("interrupt", _params, socket) do
    case Command.interrupt() do
      :ok ->
        {:noreply,
         socket |> clear_flash() |> put_flash(:info, "Interrupted current work") |> assign_data()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "Interrupt failed: #{inspect(reason)}")}
    end
  end

  def handle_event("start_loop", _params, socket) do
    {:noreply, socket |> put_flash(:info, "Use 'mix noface.start' to start the loop")}
  end

  @impl true
  def handle_info({:state, _snapshot}, %{assigns: %{test_state: test_state}} = socket)
      when is_map(test_state) do
    {:noreply, socket}
  end

  def handle_info({:state, snapshot}, socket) do
    issues =
      snapshot[:issues]
      |> Map.values()
      |> Enum.map(&present_issue/1)
      |> sort_issues()

    counts = %{
      total_issues: map_size(snapshot[:issues] || %{}),
      pending: Enum.count(issues, &(&1.status == :pending)),
      in_progress: Enum.count(issues, &(&1.status in [:assigned, :running])),
      completed: Enum.count(issues, &(&1.status == :completed)),
      failed: Enum.count(issues, &(&1.status == :failed))
    }

    stats = %{
      total: counts.total_issues,
      open: counts.pending,
      in_progress: counts.in_progress,
      closed: counts.completed + counts.failed
    }

    workers = snapshot[:workers] || []
    num_workers = snapshot[:num_workers] || length(workers)
    status = merge_status(socket.assigns.status || %{}, counts, workers, num_workers)

    {:noreply,
     assign(socket,
       issues: issues,
       stats: stats,
       workers: Enum.take(workers, num_workers),
       status: status
     )}
  end

  def handle_info({:loop, _loop_payload}, %{assigns: %{test_state: test_state}} = socket)
      when is_map(test_state) do
    {:noreply, socket}
  end

  def handle_info({:loop, loop_payload}, socket) do
    status = (socket.assigns.status || %{}) |> Map.put(:loop, loop_payload)
    {:noreply, assign(socket, status: status)}
  end

  def handle_info({:session_started, _issue_id}, %{assigns: %{test_state: test_state}} = socket)
      when is_map(test_state) do
    {:noreply, socket}
  end

  def handle_info({:session_started, issue_id}, socket) do
    sessions = Map.put_new(socket.assigns.sessions || %{}, issue_id, [])

    {:noreply,
     assign(socket,
       sessions: sessions,
       selected_session:
         pick_session(socket.assigns.selected_session, socket.assigns.issues, sessions)
     )}
  end

  def handle_info(
        {:session_event, _issue_id, _event},
        %{assigns: %{test_state: test_state}} = socket
      )
      when is_map(test_state) do
    {:noreply, socket}
  end

  def handle_info({:session_event, issue_id, event}, socket) do
    mapped = present_event(event)
    sessions = Map.update(socket.assigns.sessions || %{}, issue_id, [mapped], &(&1 ++ [mapped]))
    selected = pick_session(socket.assigns.selected_session, socket.assigns.issues, sessions)

    {:noreply, assign(socket, sessions: sessions, selected_session: selected)}
  end

  defp assign_data(socket) do
    {status, issues, sessions} =
      case socket.assigns[:test_state] do
        %{status: s, issues: i} = test ->
          {s, Enum.map(i, &present_issue/1), Map.get(test, :sessions, %{})}

        _ ->
          status = Command.status()
          issues = get_issues()
          sessions = load_sessions()
          {status, issues, sessions}
      end

    state_counts = status[:state] || %{}
    selected_session = pick_session(socket.assigns.selected_session, issues, sessions)

    stats = %{
      total: state_counts[:total_issues] || length(issues),
      open: state_counts[:pending] || Enum.count(issues, &(&1.status == :pending)),
      in_progress:
        state_counts[:in_progress] || Enum.count(issues, &(&1.status in [:assigned, :running])),
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

  defp add_comment_to_test_state(%{issues: issues} = test_state, id, author, body) do
    updated =
      Enum.map(issues, fn
        %{id: ^id} = issue ->
          comment = %{author: author, body: body, inserted_at: DateTime.utc_now()}
          comments = (Map.get(issue, :comments) || []) ++ [comment]
          content = Map.put(issue.content || %{}, :comments, comments)
          %{issue | comments: comments, content: content}

        other ->
          other
      end)

    %{test_state | issues: updated}
  end

  defp add_comment_to_test_state(test_state, _id, _author, _body), do: test_state

  defp update_test_issue_content(%{issues: issues} = test_state, id, attrs) do
    updated =
      Enum.map(issues, fn
        %{id: ^id} = issue ->
          content = Map.merge(issue.content || %{}, attrs)
          %{issue | content: content}

        other ->
          other
      end)

    %{test_state | issues: updated}
  end

  defp update_test_issue_content(test_state, _id, _attrs), do: test_state

  defp get_issues do
    try do
      State.list_issues()
      |> Enum.map(&present_issue/1)
      |> sort_issues()
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

  defp filter_issues(issues, "in_progress"),
    do: Enum.filter(issues, &(&1.status in [:assigned, :running]))

  defp filter_issues(issues, "closed"),
    do: Enum.filter(issues, &(&1.status in [:completed, :failed]))

  defp filter_issues(issues, _), do: issues

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <header class="dashboard-header">
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
            <span class="text-warning">active:</span>
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
          <div class="panel-header-actions">
            <%= if @left_tab == "issues" do %>
              <span class="text-muted"><%= length(filter_issues(@issues, @filter)) %> shown</span>
              <button class="filter-btn" phx-click="set_left_tab" phx-value-tab="graph">graph</button>
            <% else %>
              <button class="filter-btn" phx-click="set_left_tab" phx-value-tab="issues">issues</button>
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
                  <div class="issue">
                    <div class="issue-header" phx-click="toggle_issue" phx-value-id={issue.id}>
                      <span class="issue-id"><%= issue.id %></span>
                      <span class="issue-title"><%= issue.title || "(no title)" %></span>
                    </div>
                    <div class="issue-meta" phx-click="toggle_issue" phx-value-id={issue.id}>
                      <span class={"priority priority-#{issue.priority || 2}"}>
                        P<%= issue.priority || 2 %>
                      </span>
                      <span class={"issue-status #{issue.status}"}>
                        <%= issue.status %>
                      </span>
                      <%= if issue.issue_type do %>
                        <span class="text-dim"><%= String.upcase(to_string(issue.issue_type)) %></span>
                      <% end %>
                      <%= if issue.dependencies && issue.dependencies != [] do %>
                        <span class="text-dim">blocks <%= Enum.count(issue.dependencies) %></span>
                      <% end %>
                    </div>
                    <%= if @expanded == issue.id do %>
                      <div class="issue-expanded">
                        <%= if issue.description do %>
                          <div><%= issue.description %></div>
                        <% end %>
                        <%= if issue.acceptance_criteria do %>
                          <div class="issue-section">
                            <span class="issue-section-title">Acceptance:</span>
                            <pre class="text-delta"><%= issue.acceptance_criteria %></pre>
                          </div>
                        <% end %>
                        <%= if issue.dependencies && issue.dependencies != [] do %>
                          <div class="issue-section">
                            <span class="issue-section-title">Blocks:</span>
                            <span><%= Enum.map(issue.dependencies, & &1.depends_on_id) |> Enum.join(", ") %></span>
                          </div>
                        <% end %>
                    <div class="comment-box">
                      <%= if issue.comments && issue.comments != [] do %>
                        <div class="comment-list">
                          <%= for comment <- issue.comments do %>
                            <div class="comment">
                              <div class="comment-meta">
                                <%= comment.author || "user" %> · <%= format_datetime(comment.inserted_at) %>
                              </div>
                              <div><%= comment.body %></div>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                      <form phx-submit="add_comment" phx-value-id={issue.id} class="comment-form">
                        <textarea name="comment[body]" placeholder="Add comment"></textarea>
                        <div class="comment-form-footer">
                          <input type="text" name="comment[author]" placeholder="Author" value="user">
                          <button class="ctrl-btn" type="submit">Comment</button>
                        </div>
                      </form>
                    </div>
                    <form class="issue-edit-form" phx-submit="update_issue" phx-value-id={issue.id}>
                      <div class="issue-edit-field">
                        <label>Title</label>
                        <input type="text" name="issue[title]" value={issue.title} />
                      </div>
                      <div class="issue-edit-field">
                        <label>Priority</label>
                        <select name="issue[priority]" value={issue.priority || 2}>
                          <%= for p <- 0..3 do %>
                            <option value={p} selected={issue.priority == p}>P<%= p %></option>
                          <% end %>
                        </select>
                      </div>
                      <div class="issue-edit-field">
                        <label>Description</label>
                        <textarea name="issue[description]"><%= issue.description %></textarea>
                      </div>
                      <div class="issue-edit-field">
                        <label>Acceptance</label>
                        <textarea name="issue[acceptance_criteria]"><%= issue.acceptance_criteria %></textarea>
                      </div>
                      <button type="submit">Save Issue</button>
                    </form>
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
                <pre class="dep-graph"><%= for line <- lines do %><div><span class="dep-prefix"><%= line.prefix %></span><span class={line.color_class}><%= line.marker %></span> <%= line.text %></div><% end %></pre>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Right Panel: Agent Activity -->
      <div class="panel">
        <div class="panel-header">
          <span>Agent Activity</span>
          <div class="panel-header-actions">
            <span>done: <strong><%= get_in(@status, [:state, :completed]) || 0 %></strong></span>
            <span>failed: <strong><%= get_in(@status, [:state, :failed]) || 0 %></strong></span>
          </div>
        </div>

        <%= if @workers != [] do %>
          <div class="worker-grid">
            <%= for worker <- @workers do %>
              <div class="worker">
                <span class="worker-id">W<%= worker.id %></span>
                <span class={"worker-status #{worker.status}"}><%= worker.status %></span>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="controls">
          <% loop_state = loop_state(@status) %>
          <%= case loop_state do %>
            <% :running -> %>
              <button class="ctrl-btn" phx-click="pause">Pause</button>
              <button class="ctrl-btn danger" phx-click="interrupt">Interrupt</button>
            <% :paused -> %>
              <button class="ctrl-btn primary" phx-click="resume">Resume</button>
              <button class="ctrl-btn danger" phx-click="interrupt">Interrupt</button>
            <% :not_started -> %>
              <button class="ctrl-btn" phx-click="start_loop" title="Start with: mix noface.start">Start</button>
              <span class="text-dim">Loop not started</span>
          <% end %>
        </div>

        <div class="panel-content">
          <.flash_group flash={@flash} />

          <div class="loop-info">
            <div>
              <strong>Status:</strong>
              <%= case loop_state(@status) do %>
                <% :running -> %>
                  <span class="text-success">RUNNING</span>
                <% :paused -> %>
                  <span class="text-warning">PAUSED</span>
                <% :not_started -> %>
                  <span class="text-dim">NOT STARTED</span>
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

          <div class="tabs">
            <%= if map_size(@sessions) == 0 do %>
              <span class="empty-state">No sessions yet</span>
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

  defp loop_state(status) do
    cond do
      loop_paused?(status) -> :paused
      loop_running?(status) -> :running
      true -> :not_started
    end
  end

  defp progress_bar(_done, total) when total == 0, do: String.duplicate("░", 12)

  defp progress_bar(done, total) do
    width = 12
    filled = round(done / total * width)
    String.duplicate("█", filled) <> String.duplicate("░", width - filled)
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp sort_issues(issues) do
    Enum.sort_by(issues, fn issue ->
      status_order = if issue.status in [:assigned, :running], do: 0, else: 1
      {status_order, issue.priority || 2, issue.id}
    end)
  end

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
      comments:
        normalize_comments(
          Map.get(issue, :comments, []) || fetch_field(content, "comments") || []
        ),
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

  defp format_datetime(nil), do: "now"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_string(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_string(dt)
  defp format_datetime(ts) when is_binary(ts), do: ts
  defp format_datetime(_), do: "time"

  defp normalize_comments(list) when is_list(list) do
    Enum.map(list, fn
      %{"author" => a, "body" => b, "inserted_at" => ts} -> %{author: a, body: b, inserted_at: ts}
      %{author: a, body: b, inserted_at: ts} -> %{author: a, body: b, inserted_at: ts}
      other -> %{author: "user", body: inspect(other), inserted_at: nil}
    end)
  end

  defp normalize_comments(_), do: []

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
      "Read" ->
        Map.get(input, "file_path") || Map.get(input, :file_path)

      "Write" ->
        Map.get(input, "file_path") || Map.get(input, :file_path)

      "Edit" ->
        Map.get(input, "file_path") || Map.get(input, :file_path)

      "Bash" ->
        cmd = Map.get(input, "command") || Map.get(input, :command) || ""

        if is_binary(cmd) and String.length(cmd) > 60,
          do: String.slice(cmd, 0, 60) <> "...",
          else: cmd

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

    {lines, _visited} =
      roots
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {issue, idx}, {acc_lines, visited} ->
        {tree_lines, visited} =
          render_tree(issue.id, issue_map, blocks, visited, "", idx == length(roots) - 1)

        {acc_lines ++ tree_lines, visited}
      end)

    lines
  end

  defp render_tree(issue_id, issue_map, blocks, visited, prefix, is_last) do
    if MapSet.member?(visited, issue_id) do
      {[], visited}
    else
      visited = MapSet.put(visited, issue_id)
      issue = Map.get(issue_map, issue_id)
      {marker, color_class} = status_marker(issue && issue.status)
      connector = if is_last, do: "└─", else: "├─"
      title = if issue && issue.title, do: " #{issue.title}", else: ""

      line = %{
        prefix: prefix <> connector <> " ",
        marker: marker,
        color_class: color_class,
        text: "#{issue_id}#{title}"
      }

      children = Map.get(blocks, issue_id, []) |> Enum.reverse()
      child_prefix = prefix <> if is_last, do: "   ", else: "│  "
      len = length(children)

      {child_lines, visited} =
        children
        |> Enum.with_index()
        |> Enum.reduce({[], visited}, fn {child_id, idx}, {acc, v} ->
          {lines, v} = render_tree(child_id, issue_map, blocks, v, child_prefix, idx == len - 1)
          {acc ++ lines, v}
        end)

      {[line | child_lines], visited}
    end
  end

  defp status_marker(status) do
    case status do
      :completed -> {"✓", "text-success"}
      :running -> {"▶", "text-warning"}
      :assigned -> {"▶", "text-warning"}
      :failed -> {"✗", "text-danger"}
      :pending -> {"○", "text-dim"}
      _ -> {"○", "text-dim"}
    end
  end

  defp merge_status(status, counts, workers, num_workers) do
    status
    |> Map.put(:state, %{
      total_issues: counts.total_issues,
      pending: counts.pending,
      in_progress: counts.in_progress,
      completed: counts.completed,
      failed: counts.failed
    })
    |> Map.put(:workers, %{workers: workers, num_workers: num_workers})
  end
end

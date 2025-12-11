defmodule NofaceWeb.DashboardLive do
  @moduledoc """
  Real-time dashboard for noface orchestrator.

  Shows:
  - Server status and uptime
  - Loop status (running/paused/idle)
  - Issue counts by status
  - Recent activity
  - Control buttons (pause/resume/interrupt)
  """
  use Phoenix.LiveView

  alias Noface.Server.Command
  alias Noface.Core.{Loop, State}

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    {:ok, assign_status(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign_status(socket)}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    case Command.pause() do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Loop paused")
         |> assign_status()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to pause: #{inspect(reason)}")}
    end
  end

  def handle_event("resume", _params, socket) do
    case Command.resume() do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Loop resumed")
         |> assign_status()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resume: #{inspect(reason)}")}
    end
  end

  def handle_event("interrupt", _params, socket) do
    case Command.interrupt() do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Interrupted current work")
         |> assign_status()}
    end
  end

  defp assign_status(socket) do
    status = Command.status()

    assign(socket,
      server: status.server,
      loop: status.loop,
      state: status.state,
      workers: status.workers,
      page_title: "Dashboard"
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="dashboard">
      <div class="grid" style="margin-bottom: 1rem;">
        <div class="card stat">
          <div class="stat-value"><%= @state.total_issues %></div>
          <div class="stat-label">Total Issues</div>
        </div>
        <div class="card stat">
          <div class="stat-value"><%= @state.pending %></div>
          <div class="stat-label">Pending</div>
        </div>
        <div class="card stat">
          <div class="stat-value"><%= @state.in_progress %></div>
          <div class="stat-label">In Progress</div>
        </div>
        <div class="card stat">
          <div class="stat-value"><%= @state.completed %></div>
          <div class="stat-label">Completed</div>
        </div>
      </div>

      <div class="grid">
        <div class="card">
          <h2>Loop Status</h2>
          <div style="margin-bottom: 1rem;">
            <span class={status_class(@loop.running, @loop.paused)}>
              <%= status_text(@loop.running, @loop.paused) %>
            </span>
          </div>
          <div style="color: var(--text-muted); font-size: 0.875rem; margin-bottom: 1rem;">
            <div>Iteration: <%= @loop.iteration %></div>
            <div>Current: <%= inspect(@loop.current_work) || "idle" %></div>
          </div>
          <div style="display: flex; gap: 0.5rem;">
            <%= if @loop.running and not @loop.paused do %>
              <button class="btn" phx-click="pause">Pause</button>
              <button class="btn btn-danger" phx-click="interrupt">Interrupt</button>
            <% else %>
              <button class="btn btn-primary" phx-click="resume">Resume</button>
            <% end %>
          </div>
        </div>

        <div class="card">
          <h2>Server</h2>
          <div style="color: var(--text-muted); font-size: 0.875rem;">
            <div>Uptime: <%= format_uptime(@server.uptime_seconds) %></div>
            <div>Workers: <%= @workers[:active_count] || 0 %> active</div>
          </div>
        </div>

        <div class="card">
          <h2>Hot Reload</h2>
          <div style="color: var(--text-muted); font-size: 0.875rem;">
            <div>Watching lib/noface/</div>
            <div>Auto-reload on changes</div>
          </div>
        </div>
      </div>

      <div class="card" style="margin-top: 1rem;">
        <h2>Issue Summary</h2>
        <table>
          <thead>
            <tr>
              <th>Status</th>
              <th>Count</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td><span class="status-badge status-pending">Pending</span></td>
              <td><%= @state.pending %></td>
            </tr>
            <tr>
              <td><span class="status-badge status-running">In Progress</span></td>
              <td><%= @state.in_progress %></td>
            </tr>
            <tr>
              <td><span class="status-badge status-completed">Completed</span></td>
              <td><%= @state.completed %></td>
            </tr>
            <tr>
              <td><span class="status-badge status-failed">Failed</span></td>
              <td><%= @state.failed %></td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp status_class(running, paused) do
    cond do
      paused -> "status-badge status-paused"
      running -> "status-badge status-running"
      true -> "status-badge status-idle"
    end
  end

  defp status_text(running, paused) do
    cond do
      paused -> "Paused"
      running -> "Running"
      true -> "Idle"
    end
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_uptime(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
end

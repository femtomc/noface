defmodule Noface.Telemetry do
  @moduledoc """
  Telemetry instrumentation for noface.

  Defines all telemetry events and provides helper functions for emitting them.
  Also configures telemetry handlers for logging and metrics collection.

  ## Events

  ### Worker Events
  - `[:noface, :worker, :start]` - Worker begins processing an issue
  - `[:noface, :worker, :stop]` - Worker finishes (success or failure)

  ### Batch Events
  - `[:noface, :worker_pool, :batch, :start]` - Batch execution begins
  - `[:noface, :worker_pool, :batch, :stop]` - Batch execution completes

  ### State Events
  - `[:noface, :state, :loaded]` - State loaded from CubDB

  ### Agent Events
  - `[:noface, :agent, :start]` - Agent invocation begins
  - `[:noface, :agent, :stop]` - Agent invocation completes

  ### Loop Events
  - `[:noface, :loop, :iteration, :start]` - Loop iteration begins
  - `[:noface, :loop, :iteration, :stop]` - Loop iteration completes
  """

  require Logger

  @events [
    [:noface, :worker, :start],
    [:noface, :worker, :stop],
    [:noface, :worker_pool, :batch, :start],
    [:noface, :worker_pool, :batch, :stop],
    [:noface, :state, :loaded],
    [:noface, :agent, :start],
    [:noface, :agent, :stop],
    [:noface, :loop, :iteration, :start],
    [:noface, :loop, :iteration, :stop]
  ]

  @doc """
  Attach default telemetry handlers for logging.
  """
  def attach_default_handlers do
    :telemetry.attach_many(
      "noface-default-logger",
      @events,
      &handle_event/4,
      nil
    )
  end

  @doc """
  Get all defined telemetry event names.
  """
  def events, do: @events

  @doc """
  Define metrics for telemetry_metrics consumers.
  """
  def metrics do
    [
      # Worker metrics
      Telemetry.Metrics.counter("noface.worker.start.count",
        tags: [:issue_id, :worker_id]
      ),
      Telemetry.Metrics.counter("noface.worker.stop.count",
        tags: [:issue_id, :worker_id, :success]
      ),
      Telemetry.Metrics.distribution("noface.worker.stop.duration_ms",
        tags: [:issue_id, :worker_id],
        unit: :millisecond
      ),

      # Batch metrics
      Telemetry.Metrics.counter("noface.worker_pool.batch.start.count",
        tags: [:batch_id]
      ),
      Telemetry.Metrics.distribution("noface.worker_pool.batch.stop.duration_ms",
        tags: [:batch_id],
        unit: :millisecond
      ),
      Telemetry.Metrics.sum("noface.worker_pool.batch.stop.success_count",
        tags: [:batch_id]
      ),
      Telemetry.Metrics.sum("noface.worker_pool.batch.stop.failure_count",
        tags: [:batch_id]
      ),

      # Agent metrics
      Telemetry.Metrics.counter("noface.agent.start.count",
        tags: [:agent_type, :issue_id]
      ),
      Telemetry.Metrics.distribution("noface.agent.stop.duration_ms",
        tags: [:agent_type, :issue_id],
        unit: :millisecond
      ),

      # Loop metrics
      Telemetry.Metrics.counter("noface.loop.iteration.start.count"),
      Telemetry.Metrics.distribution("noface.loop.iteration.stop.duration_ms",
        unit: :millisecond
      )
    ]
  end

  # Event handlers

  defp handle_event([:noface, :worker, :start], _measurements, metadata, _config) do
    Logger.debug("[TELEMETRY] Worker #{metadata.worker_id} starting issue #{metadata.issue_id}")
  end

  defp handle_event([:noface, :worker, :stop], measurements, metadata, _config) do
    status = if measurements.success, do: "succeeded", else: "failed"
    Logger.debug("[TELEMETRY] Worker #{metadata.worker_id} #{status} in #{measurements.duration_ms}ms")
  end

  defp handle_event([:noface, :worker_pool, :batch, :start], measurements, metadata, _config) do
    Logger.info("[TELEMETRY] Batch #{metadata.batch_id} starting with #{measurements.count} issues")
  end

  defp handle_event([:noface, :worker_pool, :batch, :stop], measurements, metadata, _config) do
    Logger.info(
      "[TELEMETRY] Batch #{metadata.batch_id} completed in #{measurements.duration_ms}ms: " <>
        "#{measurements.success_count} succeeded, #{measurements.failure_count} failed"
    )
  end

  defp handle_event([:noface, :state, :loaded], measurements, metadata, _config) do
    Logger.info("[TELEMETRY] State loaded for #{metadata.project_name}: #{measurements.issue_count} issues")
  end

  defp handle_event([:noface, :agent, :start], _measurements, metadata, _config) do
    Logger.debug("[TELEMETRY] Agent #{metadata.agent_type} starting for #{metadata.issue_id}")
  end

  defp handle_event([:noface, :agent, :stop], measurements, metadata, _config) do
    Logger.debug("[TELEMETRY] Agent #{metadata.agent_type} completed in #{measurements.duration_ms}ms")
  end

  defp handle_event([:noface, :loop, :iteration, :start], measurements, _metadata, _config) do
    Logger.debug("[TELEMETRY] Loop iteration #{measurements.iteration} starting")
  end

  defp handle_event([:noface, :loop, :iteration, :stop], measurements, _metadata, _config) do
    Logger.debug("[TELEMETRY] Loop iteration completed in #{measurements.duration_ms}ms")
  end

  defp handle_event(event, measurements, metadata, _config) do
    Logger.debug("[TELEMETRY] #{inspect(event)}: #{inspect(measurements)} #{inspect(metadata)}")
  end
end

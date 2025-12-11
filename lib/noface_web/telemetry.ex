defmodule NofaceWeb.Telemetry do
  @moduledoc false

  use Supervisor

  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        unit: {:native, :millisecond}
      )
    ] ++ Noface.Telemetry.metrics()
  end

  defp periodic_measurements do
    [
      :memory,
      :total_run_queue_lengths,
      :system_counts,
      :persistent_term
    ]
  end
end

defmodule PubkyRoomsWeb.Telemetry do
  @moduledoc """
  Metric definitions for LiveDashboard (dev) or a future exporter, plus the
  10-second poller that reads `PubkyRooms.Telemetry.measure/0`. Only
  aggregate metrics with bounded tags (ADR 0006).
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Pubky Rooms (see PubkyRooms.Telemetry: counts and durations, no identifiers)
      counter("pubky_rooms.stream.connected.count"),
      counter("pubky_rooms.stream.disconnected.count", tags: [:reason]),
      counter("pubky_rooms.stream.unavailable.count", tags: [:reason]),
      summary("pubky_rooms.room.bootstrap.duration",
        unit: {:native, :millisecond},
        tags: [:status]
      ),
      summary("pubky_rooms.room.bootstrap.members"),
      summary("pubky_rooms.room.bootstrap.messages"),
      summary("pubky_rooms.message.confirm.duration", unit: :millisecond, tags: [:via]),
      summary("pubky_rooms.message.lag.duration", unit: :millisecond),
      last_value("pubky_rooms.capacity.streams"),
      last_value("pubky_rooms.capacity.pool_size"),
      last_value("pubky_rooms.capacity.users"),
      last_value("pubky_rooms.capacity.rooms"),
      last_value("pubky_rooms.capacity.directory_rooms"),
      last_value("pubky_rooms.capacity.directory_members"),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # capacity gauges + the 80 % stream-pool warning
      {PubkyRooms.Telemetry, :measure, []}
    ]
  end
end

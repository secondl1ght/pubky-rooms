defmodule Pubky.Application do
  @moduledoc """
  Supervision tree of the library: two Finch pools, the resolver cache, and the
  registry/supervisor for event streams.

  Pool sizes are per homeserver host and come from the application
  environment (`config :pubky, pools: [http: 50, streams: 100]`). The stream
  pool bounds how many `/events-stream` connections a node can hold open per
  homeserver; at 50 users per stream, the default follows 5 000 users per
  homeserver.
  """
  use Application

  @impl true
  def start(_type, _args) do
    pools = Application.get_env(:pubky, :pools, [])
    http_size = Keyword.get(pools, :http, 50)
    stream_size = Keyword.get(pools, :streams, 100)

    children = [
      {Finch, name: Pubky.Finch, pools: %{default: [size: http_size, count: 1]}},
      # Long-lived SSE connections get their own pool so they can never starve
      # ordinary request traffic.
      {Finch, name: Pubky.Finch.Streams, pools: %{default: [size: stream_size, count: 1]}},
      {Task.Supervisor, name: Pubky.TaskSupervisor},
      Pubky.Resolver,
      {Registry, keys: :unique, name: Pubky.Events.Registry},
      {DynamicSupervisor, name: Pubky.Events.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Pubky.Supervisor)
  end
end

defmodule PubkyRooms.Application do
  @moduledoc """
  The Pubky Rooms supervision tree (see docs/notes/rooms-app-design.md).
  """

  use Application

  @impl true
  def start(_type, _args) do
    PubkyRooms.Ids.init()

    children = [
      PubkyRoomsWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:pubky_rooms, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PubkyRooms.PubSub},
      {Task.Supervisor, name: PubkyRooms.TaskSupervisor},
      PubkyRooms.RateLimit,
      PubkyRooms.Events.Cursors,
      PubkyRooms.Auth.SessionStore,
      PubkyRooms.Events.Subscriptions,
      PubkyRooms.Rooms.Directory,
      {Registry, keys: :unique, name: PubkyRooms.Rooms.Registry},
      {DynamicSupervisor, name: PubkyRooms.Rooms.RoomSupervisor, strategy: :one_for_one},
      PubkyRoomsWeb.Presence,
      # Start to serve requests, typically the last entry
      PubkyRoomsWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PubkyRooms.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PubkyRoomsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

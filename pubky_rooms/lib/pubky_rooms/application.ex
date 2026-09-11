defmodule PubkyRooms.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PubkyRoomsWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:pubky_rooms, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PubkyRooms.PubSub},
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

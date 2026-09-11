defmodule Pubky.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: Pubky.Finch},
      # Long-lived SSE connections get their own pool so they can never starve
      # ordinary request traffic.
      {Finch, name: Pubky.Finch.Streams, pools: %{default: [size: 100, count: 1]}},
      {Task.Supervisor, name: Pubky.TaskSupervisor},
      # Pubky.Resolver is added once implemented (Milestone 1).
      {Registry, keys: :unique, name: Pubky.Events.Registry},
      {DynamicSupervisor, name: Pubky.Events.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Pubky.Supervisor)
  end
end

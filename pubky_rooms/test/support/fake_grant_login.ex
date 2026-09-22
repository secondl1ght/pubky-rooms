defmodule PubkyRooms.Auth.FakeGrantLogin do
  @moduledoc """
  A stand-in for `PubkyRooms.Auth.GrantLogin` in LiveView tests: no relay, no
  Ring. `start/0` hands out a flow, `await/2` waits until the test calls
  `resolve/1` with the outcome the Ring would have produced.
  """
  use Agent

  alias PubkyRooms.Auth.GrantLogin

  def start_link(_opts \\ []),
    do: Agent.start_link(fn -> %{pending: nil, flows: 0} end, name: __MODULE__)

  @doc "Clears any queued outcome."
  def reset, do: Agent.update(__MODULE__, fn _ -> %{pending: nil, flows: 0} end)

  @doc "How many flows were started."
  def flows, do: Agent.get(__MODULE__, & &1.flows)

  @doc "Delivers the outcome of the flow currently awaited: `{:ok, session}` or `{:error, reason}`."
  def resolve(result), do: Agent.update(__MODULE__, &%{&1 | pending: result})

  def capabilities, do: GrantLogin.capabilities()

  def start do
    Agent.update(__MODULE__, &%{&1 | flows: &1.flows + 1})
    %{id: System.unique_integer([:positive])}
  end

  def authorization_url(%{id: id}),
    do: "pubkyauth://signin_grant?caps=%2Fpub%2Fpubky-rooms%2F%3Arw&cid=rooms.test&flow=#{id}"

  def await(_flow, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(deadline)
  end

  defp poll(deadline) do
    case Agent.get_and_update(__MODULE__, fn s -> {s.pending, %{s | pending: nil}} end) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :expired}
        else
          Process.sleep(10)
          poll(deadline)
        end

      result ->
        result
    end
  end
end

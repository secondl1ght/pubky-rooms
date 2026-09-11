defmodule Pubky.Test.FakeRelay do
  @moduledoc """
  An in-memory HTTP relay (`/inbox/{id}` store-and-forward with ACK) served
  by a throwaway Cowboy listener. Long-polls wait up to `poll_timeout_ms` (default 200 ms) and
  answer 408 when nothing arrives, like the real relay.
  """

  import Plug.Conn

  defstruct [:ref, :agent, :base_url, poll_timeout_ms: 200]

  def start(opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> %{messages: %{}, relay: nil} end)
    ref = make_ref()
    {:ok, _} = Plug.Cowboy.http(__MODULE__.Plug, agent, port: 0, ref: ref)

    relay = %__MODULE__{
      ref: ref,
      agent: agent,
      base_url: "http://localhost:#{:ranch.get_port(ref)}/inbox/",
      poll_timeout_ms: Keyword.get(opts, :poll_timeout_ms, 200)
    }

    Agent.update(agent, &%{&1 | relay: relay})
    ExUnit.Callbacks.on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    relay
  end

  defmodule Plug do
    @moduledoc false
    alias Pubky.Test.FakeRelay

    @behaviour Elixir.Plug

    @impl true
    def init(agent), do: agent

    @impl true
    def call(conn, agent) do
      relay = Agent.get(agent, & &1.relay)
      FakeRelay.handle(conn, relay)
    end
  end

  def messages(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1.messages)

  @doc false
  def handle(%{request_path: "/inbox/" <> id} = conn, relay) do
    case {conn.method, String.split(id, "/")} do
      {"POST", [id]} ->
        {:ok, body, conn} = read_body(conn)
        Agent.update(relay.agent, &%{&1 | messages: Map.put(&1.messages, id, body)})
        resp(conn, 200, "")

      {"GET", [id]} ->
        case wait(relay, id, relay.poll_timeout_ms) do
          {:ok, body} ->
            conn |> put_resp_header("content-type", "application/octet-stream") |> resp(200, body)

          :timeout ->
            resp(conn, 408, "")
        end

      {"DELETE", [id]} ->
        Agent.update(relay.agent, &%{&1 | messages: Map.delete(&1.messages, id)})
        resp(conn, 200, "")

      _ ->
        resp(conn, 404, "")
    end
  end

  def handle(conn, _relay), do: resp(conn, 404, "")

  defp wait(relay, id, remaining) do
    case Agent.get(relay.agent, &Map.get(&1.messages, id)) do
      nil when remaining > 0 ->
        Process.sleep(20)
        wait(relay, id, remaining - 20)

      nil ->
        :timeout

      body ->
        {:ok, body}
    end
  end
end

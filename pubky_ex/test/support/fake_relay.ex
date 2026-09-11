defmodule Pubky.Test.FakeRelay do
  @moduledoc """
  An in-memory HTTP relay (`/inbox/{id}` store-and-forward with ACK) served
  through Bypass. Long-polls wait up to `poll_timeout_ms` (default 200 ms) and
  answer 408 when nothing arrives, like the real relay.
  """

  import Plug.Conn

  defstruct [:bypass, :agent, :base_url, poll_timeout_ms: 200]

  def start(opts \\ []) do
    bypass = Bypass.open()
    {:ok, agent} = Agent.start_link(fn -> %{} end)

    relay = %__MODULE__{
      bypass: bypass,
      agent: agent,
      base_url: "http://localhost:#{bypass.port}/inbox/",
      poll_timeout_ms: Keyword.get(opts, :poll_timeout_ms, 200)
    }

    Bypass.stub(bypass, :any, :any, &handle(&1, relay))
    relay
  end

  def messages(%__MODULE__{agent: agent}), do: Agent.get(agent, & &1)

  defp handle(%{request_path: "/inbox/" <> id} = conn, relay) do
    case {conn.method, String.split(id, "/")} do
      {"POST", [id]} ->
        {:ok, body, conn} = read_body(conn)
        Agent.update(relay.agent, &Map.put(&1, id, body))
        resp(conn, 200, "")

      {"GET", [id]} ->
        case wait(relay, id, relay.poll_timeout_ms) do
          {:ok, body} ->
            conn |> put_resp_header("content-type", "application/octet-stream") |> resp(200, body)

          :timeout ->
            resp(conn, 408, "")
        end

      {"DELETE", [id]} ->
        Agent.update(relay.agent, &Map.delete(&1, id))
        resp(conn, 200, "")

      _ ->
        resp(conn, 404, "")
    end
  end

  defp handle(conn, _relay), do: resp(conn, 404, "")

  defp wait(relay, id, remaining) do
    case Agent.get(relay.agent, &Map.get(&1, id)) do
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

defmodule PubkyRoomsWeb.HealthController do
  @moduledoc """
  `GET /healthz` for platform health checks: 200 with aggregate counts while
  every core process runs, 503 naming what is missing (ADR 0006: counts only,
  no identifiers).
  """
  use PubkyRoomsWeb, :controller

  def show(conn, _params) do
    case PubkyRooms.Telemetry.health() do
      {:ok, body} -> json(conn, body)
      {:error, body} -> conn |> put_status(:service_unavailable) |> json(body)
    end
  end
end

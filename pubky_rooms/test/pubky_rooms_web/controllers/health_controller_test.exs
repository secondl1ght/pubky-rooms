defmodule PubkyRoomsWeb.HealthControllerTest do
  use PubkyRoomsWeb.ConnCase, async: true

  test "GET /healthz answers 200 with aggregate counts and no session", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert %{"status" => "ok", "streams" => s, "stream_pool" => p, "rooms" => r} =
             json_response(conn, 200)

    assert is_integer(s) and is_integer(p) and is_integer(r)
    refute Map.has_key?(json_response(conn, 200), "missing")
    assert get_resp_header(conn, "set-cookie") == []
  end
end

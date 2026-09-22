defmodule PubkyRoomsWeb.Plugs.SecurityHeadersTest do
  use PubkyRoomsWeb.ConnCase, async: true

  alias PubkyRoomsWeb.Plugs.SecurityHeaders

  test "HTML responses carry a strict CSP with a per-request script nonce", %{conn: conn} do
    conn = get(conn, ~p"/")
    [csp] = get_resp_header(conn, "content-security-policy")

    assert csp =~ "default-src 'self'"
    assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([A-Za-z0-9_-]{22})'/, csp)
    assert conn.assigns.csp_nonce == nonce
    refute csp =~ "unsafe-eval"
    assert csp =~ "style-src 'self' 'unsafe-inline'"
    assert csp =~ "img-src 'self' data: https:"
    assert csp =~ "connect-src 'self' ws://www.example.com wss://www.example.com"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "object-src 'none'"
    assert csp =~ "form-action 'self'"
    assert csp =~ "worker-src 'self'"
    assert csp =~ "manifest-src 'self'"
    refute csp =~ ~r/https?:\/\/(?!www\.example\.com)/, "no third-party origin in the policy"

    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    [permissions] = get_resp_header(conn, "permissions-policy")
    assert permissions =~ "camera=()" and permissions =~ "geolocation=()"

    # a second request gets a different nonce
    other = get(build_conn(), ~p"/")
    assert other.assigns.csp_nonce != nonce
  end

  test "the socket origin follows the request host and non-default port" do
    conn = %Plug.Conn{build_conn() | host: "rooms.test", port: 4000, scheme: :http}

    assert SecurityHeaders.policy(conn, "n") =~
             "connect-src 'self' ws://rooms.test:4000 wss://rooms.test:4000"

    conn = %Plug.Conn{build_conn() | host: "rooms.pubky.app", port: 443, scheme: :https}

    assert SecurityHeaders.policy(conn, "n") =~
             "connect-src 'self' ws://rooms.pubky.app wss://rooms.pubky.app"
  end

  test "the health endpoint stays plain (no session cookie, no HTML headers)", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert conn.status == 200
    assert get_resp_header(conn, "content-security-policy") == []
    assert get_resp_header(conn, "set-cookie") == []
  end
end

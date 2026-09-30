defmodule PubkyRoomsWeb.SessionLoggingTest do
  use PubkyRoomsWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias PubkyRooms.Fixtures

  # The grant credential lives in the encrypted cookie session (ADR 0005);
  # Phoenix decrypts it for every request, so nothing may ever print the
  # session — not even at debug, where LiveView's own logger would.
  test "no log level prints the session: LiveView mounts, params and requests stay silent about it",
       %{conn: conn} do
    {sid, _user} = Fixtures.login("quiet")
    cookie = Fixtures.cookie(sid)
    conn = init_test_session(conn, cookie)
    previous = Logger.level()
    Logger.configure(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        {:ok, view, _html} = live(conn, ~p"/me")
        render(view)
        {:ok, _view, _html} = live(conn, ~p"/")
        _ = get(conn, ~p"/me")
      end)

    Logger.configure(level: previous)

    # logging was on: the requests themselves are there
    assert log =~ "GET /me"
    refute log =~ cookie["cred"]
    refute log =~ "pubky-grant-credential"
    refute log =~ sid
    refute log =~ "MOUNT"
  end
end

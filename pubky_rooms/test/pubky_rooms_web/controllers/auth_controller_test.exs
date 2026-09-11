defmodule PubkyRoomsWeb.AuthControllerTest do
  use PubkyRoomsWeb.ConnCase, async: false

  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Fixtures
  alias PubkyRoomsWeb.AuthController

  setup do
    PubkyRooms.RateLimit.reset()
    :ok
  end

  test "a valid handoff token signs the browser in, once", %{conn: conn} do
    {sid, _user} = Fixtures.login("handoff")
    token = AuthController.handoff_token(sid)

    conn = get(conn, ~p"/auth/complete?token=#{token}&return_to=/rooms/new")
    assert redirected_to(conn) == "/rooms/new"
    assert get_session(conn, :sid) == sid

    # the same token cannot be replayed
    replay = get(build_conn(), ~p"/auth/complete?token=#{token}")
    assert redirected_to(replay) == ~p"/login"
    assert get_session(replay, :sid) == nil
  end

  test "garbage and unknown-session tokens are rejected", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/auth/complete?token=nope")) == ~p"/login"
    token = AuthController.handoff_token("not-a-session")
    assert redirected_to(get(build_conn(), ~p"/auth/complete?token=#{token}")) == ~p"/login"
  end

  test "return_to only accepts local paths", %{conn: conn} do
    {sid, _} = Fixtures.login("evil")
    token = AuthController.handoff_token(sid)
    conn = get(conn, ~p"/auth/complete?token=#{token}&return_to=https://evil.example")
    assert redirected_to(conn) == "/"
  end

  test "logout forgets the session", %{conn: conn} do
    {sid, _} = Fixtures.login("bye")
    conn = conn |> init_test_session(sid: sid) |> delete(~p"/logout")
    assert redirected_to(conn) == "/"
    assert SessionStore.lookup(sid) == :error
  end
end

defmodule PubkyRooms.Auth.SessionStoreTest do
  use ExUnit.Case, async: false

  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Fixtures

  test "put/cookie_session/lookup/user_of/call/delete" do
    user = Fixtures.z32("store")
    sid = SessionStore.put(Fixtures.session(user))
    assert String.length(sid) == 32

    assert %{"sid" => ^sid, "pubky" => ^user, "cred" => "pubky-grant-credential-v1:" <> _} =
             SessionStore.cookie_session(sid)

    assert SessionStore.user_of(sid) == user
    assert {:ok, %Pubky.Session{user: ^user}} = SessionStore.lookup(sid)
    assert {:ok, {:hello, ^user}} = SessionStore.call(sid, fn s -> {:ok, {:hello, s.user}} end)
    assert {:error, :boom} = SessionStore.call(sid, fn _ -> {:error, :boom} end)
    assert SessionStore.delete(sid) == :ok
    assert SessionStore.lookup(sid) == :error
    assert SessionStore.user_of(sid) == nil
    assert SessionStore.cookie_session(sid) == nil
    assert {:error, :no_session} = SessionStore.call(sid, fn _ -> :ok end)
    assert SessionStore.lookup("nope") == :error
  end

  test "a cookie re-seeds a forgotten session without touching the network" do
    user = Fixtures.z32("cookie")
    sid = SessionStore.put(Fixtures.session(user))
    cookie = SessionStore.cookie_session(sid)

    # simulate a restart: the memory cache is empty, the browser still has the cookie
    :ets.delete(:pubky_sessions, sid)
    assert SessionStore.user_of(sid) == nil
    assert SessionStore.ensure(cookie) == sid
    assert SessionStore.user_of(sid) == user
    # cold entry: no bearer until first use
    assert [{^sid, %{session: nil}}] = :ets.lookup(:pubky_sessions, sid)
    SessionStore.delete(sid)
  end

  test "malformed cookies are rejected" do
    assert SessionStore.ensure(%{}) == nil
    assert SessionStore.ensure(%{"sid" => "x", "pubky" => "y", "cred" => "garbage"}) == nil

    assert SessionStore.ensure(%{
             "sid" => "x",
             "pubky" => "y",
             "cred" => "pubky-grant-credential-v1:bad"
           }) == nil

    assert SessionStore.user_of("x") == nil
  end
end

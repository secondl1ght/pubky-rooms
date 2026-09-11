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

  test "sessions are dropped shortly after the last attached process leaves" do
    user = Fixtures.z32("attach")
    sid = SessionStore.put(Fixtures.session(user))

    {:ok, pid} = Agent.start_link(fn -> nil end)
    SessionStore.attach(sid, pid)
    Process.sleep(20)
    # the sweep never removes an attached session, however old
    [{^sid, entry}] = :ets.lookup(:pubky_sessions, sid)
    :ets.insert(:pubky_sessions, {sid, %{entry | last_used: -1_000_000_000_000}})
    send(SessionStore, :sweep)
    Process.sleep(20)
    assert SessionStore.user_of(sid) == user

    # after the last process leaves, the entry expires (60 s grace in production; forced here)
    Agent.stop(pid)
    Process.sleep(20)
    send(SessionStore, {:expire, sid})
    Process.sleep(20)
    assert SessionStore.user_of(sid) == nil
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

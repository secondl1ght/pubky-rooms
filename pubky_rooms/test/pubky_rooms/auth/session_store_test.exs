defmodule PubkyRooms.Auth.SessionStoreTest do
  use ExUnit.Case, async: false

  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Fixtures

  test "put/lookup/user_of/call/delete" do
    user = Fixtures.z32("store")
    sid = SessionStore.put(Fixtures.session(user))
    assert String.length(sid) == 32
    assert SessionStore.user_of(sid) == user
    assert {:ok, %Pubky.Session{user: ^user}} = SessionStore.lookup(sid)
    assert {:ok, {:hello, ^user}} = SessionStore.call(sid, fn s -> {:ok, {:hello, s.user}} end)
    assert {:error, :boom} = SessionStore.call(sid, fn _ -> {:error, :boom} end)
    assert SessionStore.delete(sid) == :ok
    assert SessionStore.lookup(sid) == :error
    assert SessionStore.user_of(sid) == nil
    assert {:error, :no_session} = SessionStore.call(sid, fn _ -> :ok end)
    assert SessionStore.lookup("nope") == :error
  end

  test "credentials are stored encrypted in DETS" do
    user = Fixtures.z32("secret")
    sid = SessionStore.put(Fixtures.session(user))
    [{^sid, %{credential: cipher}}] = :dets.lookup(:pubky_sessions_dets, sid)
    refute String.contains?(cipher, "pubky-grant-credential")
    SessionStore.delete(sid)
  end
end

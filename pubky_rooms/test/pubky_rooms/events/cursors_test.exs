defmodule PubkyRooms.Events.CursorsTest do
  use ExUnit.Case, async: false

  alias Pubky.Events.Event
  alias PubkyRooms.Events
  alias PubkyRooms.Events.Cursors
  alias PubkyRooms.Fixtures

  test "advance keeps the newest cursor and dispatch drops replays" do
    user = Fixtures.z32("cursors")
    Events.subscribe_user(user)

    ev = %Event{
      type: :put,
      user: user,
      path: "/pub/pubky-rooms/x",
      uri: "pubky://#{user}/pub/pubky-rooms/x",
      cursor: 10,
      content_hash: nil,
      homeserver: "hs"
    }

    assert Events.dispatch(ev) == :ok
    assert_receive {:pubky_event, %Event{cursor: 10}}
    assert Events.dispatch(%{ev | cursor: 9}) == :stale
    assert Events.dispatch(%{ev | cursor: 10}) == :stale
    refute_receive {:pubky_event, _}
    assert Events.dispatch(%{ev | cursor: 11}) == :ok
    assert Cursors.get(user) == 11
  end
end

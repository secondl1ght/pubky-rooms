defmodule PubkyRooms.Rooms.PathsTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Fixtures
  alias PubkyRooms.Rooms.Paths

  @creator Fixtures.z32("creator")
  @author Fixtures.z32("author")
  @id "0000000000001"
  @msg "0000000000002"

  test "builds and parses every kind of path" do
    ref = {@creator, @id}
    assert Paths.parse(Paths.room(@id)) == {:room, @id}
    assert Paths.parse(Paths.member(ref)) == {:member, @creator, @id}
    assert Paths.parse(Paths.message(ref, @msg)) == {:message, @creator, @id, @msg}

    assert Paths.parse(Paths.reaction(ref, @author, @msg, "heart")) ==
             {:reaction, @creator, @id, @author, @msg, "heart"}

    assert Paths.parse(Paths.ban(@id, @author)) == {:ban, @id, @author}
    assert Paths.parse(Paths.tag(String.duplicate("A", 26))) == {:tag, String.duplicate("A", 26)}
    assert Paths.parse(Paths.profile()) == :profile
  end

  test "rejects malformed segments and foreign paths" do
    assert Paths.parse("/pub/pubky.app/posts/1") == :ignore
    assert Paths.parse("/pub/pubky-rooms/rooms/not-an-id") == :ignore
    assert Paths.parse("/pub/pubky-rooms/rooms/#{@id}/extra") == :ignore
    assert Paths.parse("/pub/pubky-rooms/members/short/#{@id}") == :ignore
    assert Paths.parse("/pub/pubky-rooms/messages/#{@creator}/#{@id}/../x") == :ignore

    assert Paths.parse("/pub/pubky-rooms/reactions/#{@creator}/#{@id}/#{@author}/#{@msg}/HEART") ==
             :ignore

    assert Paths.parse(nil) == :ignore
  end

  test "room and message URIs round-trip" do
    ref = {@creator, @id}
    assert Paths.room_uri(ref) == "pubky://#{@creator}/pub/pubky-rooms/rooms/#{@id}"
    assert Paths.parse_room_uri(Paths.room_uri(ref)) == {:ok, ref}

    assert Paths.parse_room_uri("pubky://#{@creator}/pub/pubky-rooms/members/#{@creator}/#{@id}") ==
             :error

    uri = Paths.message_uri(@author, ref, @msg)
    assert Paths.parse_message_uri(uri) == {:ok, {@author, ref, @msg}}
    assert Paths.parse_message_uri("https://example.com") == :error
  end
end

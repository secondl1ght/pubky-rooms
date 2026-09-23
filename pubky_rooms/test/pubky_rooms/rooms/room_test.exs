defmodule PubkyRooms.Rooms.RoomTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Fixtures
  alias PubkyRooms.Rooms.{Membership, Message, Room}

  @creator Fixtures.z32("creator")

  test "new/encode/decode round-trip" do
    {:ok, room} =
      Room.new(@creator, %{"name" => "  Bitcoin devs ", "topic" => "", "visibility" => "public"})

    assert room.name == "Bitcoin devs"
    assert room.topic == nil
    assert {:ok, decoded} = Room.decode(Room.encode(room), @creator, room.id)
    assert decoded == room
  end

  test "validation errors are form-friendly" do
    assert {:error, errors} = Room.validate(%{"name" => "", "visibility" => "secret"})
    assert Keyword.has_key?(errors, :name)
    assert Keyword.has_key?(errors, :visibility)

    assert {:error, [topic: _]} =
             Room.validate(%{
               "name" => "ok",
               "topic" => String.duplicate("x", 281),
               "visibility" => "public"
             })
  end

  test "decode rejects garbage, wrong versions and oversized bodies" do
    id = "0000000000001"
    assert Room.decode("nope", @creator, id) == {:error, :invalid_json}

    assert Room.decode(~s({"v":2,"name":"x","visibility":"public","created_at":1}), @creator, id) ==
             {:error, :unsupported_version}

    assert Room.decode(String.duplicate(" ", 20_000), @creator, id) == {:error, :too_large}

    assert {:error, :invalid_timestamp} =
             Room.decode(
               ~s({"v":1,"name":"x","visibility":"public","created_at":"soon"}),
               @creator,
               id
             )
  end

  test "messages validate content and reply targets" do
    ref = {@creator, "0000000000001"}
    author = Fixtures.z32("author")
    assert {:error, "Write a message first."} = Message.new(author, ref, "   ")
    assert {:error, _} = Message.new(author, ref, String.duplicate("x", 2001))
    assert {:ok, msg} = Message.new(author, ref, " gm ")
    assert msg.content == "gm"
    assert msg.state == :pending
    assert msg.key == {msg.msg_id, author}

    assert msg.uri ==
             "pubky://#{author}/pub/pubky-rooms/messages/#{@creator}/0000000000001/#{msg.msg_id}"

    assert {:ok, decoded} = Message.decode(Message.encode(msg), author, ref, msg.msg_id)
    assert decoded.state == :confirmed
    assert %{decoded | state: :pending} == msg

    other_room_msg =
      "pubky://#{author}/pub/pubky-rooms/messages/#{@creator}/0000000000009/0000000000002"

    assert {:error, :invalid_reply_to} = Message.new(author, ref, "hi", reply_to: other_room_msg)
    assert {:ok, %{reply_to: r}} = Message.new(author, ref, "hi", reply_to: msg.uri)
    assert r == msg.uri

    assert {:error, :unsupported_kind} =
             Message.decode(
               ~s({"v":1,"kind":"image","content":"x","created_at":1}),
               author,
               ref,
               "0000000000002"
             )
  end

  test "join markers must point at their own room" do
    ref = {@creator, "0000000000001"}
    assert {:ok, %{joined_at: _}} = Membership.decode(Membership.encode(ref), ref)

    assert {:error, :room_mismatch} =
             Membership.decode(Membership.encode({@creator, "0000000000002"}), ref)

    assert {:error, :invalid_json} = Membership.decode("{", ref)
  end
end

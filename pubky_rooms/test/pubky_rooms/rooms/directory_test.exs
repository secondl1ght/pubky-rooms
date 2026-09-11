defmodule PubkyRooms.Rooms.DirectoryTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Directory, Membership, Paths, Room}

  setup do
    reset_state()
    Directory.subscribe()
    :ok
  end

  test "create_room records the room and creator membership; events add members" do
    {sid, alice} = Fixtures.login("alice")
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Lobby", "visibility" => "unlisted"})
    ref = Room.ref(room)
    assert_receive {:directory, {:room_updated, %Room{name: "Lobby"}}}
    assert Directory.get(ref) == room
    assert Directory.members_of(ref) == [alice]
    assert %{created: [^room], joined: []} = Directory.rooms_of(alice)
    assert Map.has_key?(Fake.files(alice), Paths.room(room.id))
    assert Map.has_key?(Fake.files(alice), Paths.member(ref))

    bob = Fixtures.z32("bob")
    Fake.write_as(bob, Paths.member(ref), Membership.encode(ref))
    assert_receive {:directory, {:member_joined, ^ref, ^bob}}, 1_000
    assert bob in Directory.members_of(ref)
    assert %{joined: [^room]} = Directory.rooms_of(bob)
  end

  test "sync_user discovers rooms and memberships from the homeserver" do
    alice = Fixtures.z32("alice")
    carol = Fixtures.z32("carol")
    {:ok, room} = Room.new(alice, %{"name" => "Synced", "visibility" => "public"})
    ref = Room.ref(room)
    Fake.seed(alice, Paths.room(room.id), Room.encode(room))
    Fake.seed(carol, Paths.member(ref), Membership.encode(ref))

    Directory.sync_user(carol, force: true)
    assert_receive {:directory, {:room_updated, %Room{name: "Synced"}}}, 2_000
    assert_receive {:directory, {:member_joined, ^ref, ^carol}}, 2_000
    assert Directory.member?(ref, carol)
  end

  test "validation errors and rate limits surface from create_room" do
    {sid, alice} = Fixtures.login("alice")

    assert {:error, [name: _]} =
             Rooms.create_room(sid, alice, %{"name" => "", "visibility" => "public"})

    for i <- 1..5 do
      assert {:ok, _} =
               Rooms.create_room(sid, alice, %{"name" => "Room #{i}", "visibility" => "public"})
    end

    assert {:error, {:rate_limited, _}} =
             Rooms.create_room(sid, alice, %{"name" => "Room 6", "visibility" => "public"})
  end
end

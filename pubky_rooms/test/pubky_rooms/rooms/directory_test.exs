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

  test "activity never runs ahead of the clock, and only members' messages count" do
    {sid, alice} = Fixtures.login("alice")
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Clock", "visibility" => "public"})
    ref = Room.ref(room)
    assert_receive {:directory, {:room_updated, %Room{name: "Clock"}}}

    # a message body may claim any created_at; the lobby order cannot be pinned with it
    Directory.touch(ref, 9_999_999_999_999)
    assert_receive {:directory, {:room_updated, %Room{name: "Clock"}}}
    assert Directory.last_activity(ref) <= System.os_time(:millisecond) + :timer.minutes(5)

    # a stranger writing a message file that names this room does not bump it
    Process.sleep(50)
    before = Directory.last_activity(ref)
    mallory = Fixtures.z32("mallory")
    Fake.write_as(mallory, Paths.message(ref, "0035S410XTQ99"), "{}")
    Process.sleep(100)
    assert Directory.last_activity(ref) == before
  end

  test "a membership is recorded once its room is known; markers for rooms that do not exist record nothing" do
    alice = Fixtures.z32("alice")
    bob = Fixtures.z32("bob")
    {:ok, room} = Room.new(alice, %{"name" => "Early", "visibility" => "public"})
    ref = Room.ref(room)
    # the room exists on alice's homeserver but this node has not seen it yet
    Fake.seed(alice, Paths.room(room.id), Room.encode(room))

    # bob's marker event arrives first: the room is fetched, then bob is added
    Fake.write_as(bob, Paths.member(ref), Membership.encode(ref))
    assert_receive {:directory, {:room_updated, %Room{name: "Early"}}}, 2_000
    assert_receive {:directory, {:member_joined, ^ref, ^bob}}, 2_000
    assert Directory.member?(ref, bob)

    # a marker for a room nobody ever wrote leaves nothing behind
    ghost = {alice, "0035S410XTQ77"}
    mallory = Fixtures.z32("mallory")
    Fake.write_as(mallory, Paths.member(ghost), Membership.encode(ghost))
    refute_receive {:directory, {:member_joined, ^ghost, ^mallory}}, 300
    refute Directory.member?(ghost, mallory)
    assert Directory.get(ghost) == nil

    # rows an older build persisted for unknown rooms are dropped when the tables are rebuilt
    :ok = :dets.insert(:rooms_directory_dets, {{:member, ghost, mallory}, 1})
    :ok = GenServer.call(Directory, :reload)
    refute Directory.member?(ghost, mallory)
    assert Directory.member?(ref, bob)
    assert :dets.lookup(:rooms_directory_dets, {:member, ghost, mallory}) == []
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

  test "closing keeps the room as an archive for its members, out of discovery, until swept" do
    {sid, alice} = Fixtures.login("alice")
    bob = Fixtures.z32("bob")

    {:ok, room} =
      Rooms.create_room(sid, alice, %{
        "name" => "Ephemeral",
        "visibility" => "public",
        "tags" => "sunset"
      })

    ref = Room.ref(room)
    Fake.write_as(bob, Paths.member(ref), Membership.encode(ref))
    assert_receive {:directory, {:member_joined, ^ref, ^bob}}, 1_000
    assert Enum.any?(Directory.public_rooms(), &(Room.ref(&1) == ref))
    assert {"sunset", 1} in Directory.popular_tags()

    :ok = Rooms.close_room(sid, alice, room)
    assert_receive {:directory, {:room_closed, %Room{closed_at: closed_at}}}, 1_000
    assert is_integer(closed_at)

    # still known, members intact, listed apart for both of them
    assert %Room{name: "Ephemeral", closed_at: ^closed_at} = Directory.get(ref)
    assert Enum.sort(Directory.members_of(ref)) == Enum.sort([alice, bob])
    assert %{created: [], joined: [], closed: [%Room{id: id}]} = Directory.rooms_of(alice)
    assert id == room.id
    assert %{joined: [], closed: [%Room{id: ^id}]} = Directory.rooms_of(bob)

    # gone from discovery
    refute Enum.any?(Directory.public_rooms(), &(Room.ref(&1) == ref))
    refute Enum.any?(Directory.popular_tags(), fn {label, _} -> label == "sunset" end)

    # closing twice keeps the original timestamp; a room DEL event closes too
    :ok = Directory.close_room(ref)
    assert %Room{closed_at: ^closed_at} = Directory.get(ref)

    {:ok, other} = Rooms.create_room(sid, alice, %{"name" => "Other", "visibility" => "unlisted"})
    other_ref = Room.ref(other)
    Fake.delete_as(alice, Paths.room(other.id))
    assert_receive {:directory, {:room_closed, %Room{id: other_id}}}, 1_000
    assert other_id == other.id

    # the sweep forgets closed rooms with no activity for the TTL, nothing else
    ttl = Application.get_env(:pubky_rooms, :closed_room_ttl_ms, :timer.hours(24 * 90))
    assert Directory.sweep_closed(System.os_time(:millisecond) + ttl - 1_000) == 0
    Directory.touch(other_ref, System.os_time(:millisecond) + 60_000)
    assert Directory.sweep_closed(System.os_time(:millisecond) + ttl + 30_000) == 1
    assert Directory.get(ref) == nil
    assert_receive {:directory, {:room_removed, ^ref}}, 1_000
    assert %Room{} = Directory.get(other_ref)
    assert Directory.members_of(ref) == [alice]
    assert %{closed: []} = Directory.rooms_of(bob)
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

defmodule PubkyRooms.Rooms.RoomServerTest do
  use ExUnit.Case, async: false

  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Directory, Message, Paths, RoomServer}

  setup do
    Fake.reset()
    Directory.reset()
    PubkyRooms.Events.Cursors.reset()
    PubkyRooms.RateLimit.reset()
    {sid, alice} = Fixtures.login("alice")

    {:ok, room} =
      Rooms.create_room(sid, alice, %{"name" => "Test room", "visibility" => "public"})

    ref = Rooms.Room.ref(room)
    Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(ref))
    %{sid: sid, alice: alice, room: room, ref: ref}
  end

  test "bootstraps from the creator's homeserver and backfills history", %{
    alice: alice,
    ref: ref,
    sid: sid
  } do
    {:ok, m1} = Message.new(alice, ref, "first")
    Fake.seed(alice, Message.path(m1), Message.encode(m1))

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{status: :ready, table: table, members: members, room: room}} = RoomServer.attach(ref)
    assert room.name == "Test room"
    assert alice in members
    assert [%Message{content: "first", state: :confirmed}] = RoomServer.history(table)

    # a message written by this node is confirmed by its event hash, without a fetch
    {:ok, msg} = Rooms.prepare_message(sid, alice, ref, "hello")
    assert msg.state == :pending
    assert :ok = Rooms.publish_message(sid, msg)

    assert_receive {:room_event, ^ref,
                    {:message_upserted, %Message{content: "hello", state: :confirmed}}},
                   1_000

    assert [_, %Message{content: "hello"}] = RoomServer.history(table)

    # a message from another client (no pending entry) is fetched
    {:ok, other} = Message.new(alice, ref, "from another client")
    Fake.write_as(alice, Message.path(other), Message.encode(other))

    assert_receive {:room_event, ^ref,
                    {:message_upserted, %Message{content: "from another client"}}},
                   1_000

    # deletion
    Fake.delete_as(alice, Message.path(other))
    key = other.key
    assert_receive {:room_event, ^ref, {:message_deleted, ^key}}, 1_000
    refute Enum.any?(RoomServer.history(table), &(&1.key == key))
  end

  test "a failed write cancels the pending entry and a vanished one is reported", %{
    alice: alice,
    ref: ref,
    sid: sid
  } do
    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, _} = RoomServer.attach(ref)

    {:ok, msg} = Rooms.prepare_message(sid, alice, ref, "will fail")
    Fake.fail_next(Message.path(msg), :quota)
    assert {:error, :quota} = Rooms.publish_message(sid, msg)

    # pending but never written → the sweep verifies and reports it
    {:ok, ghost} = Rooms.prepare_message(sid, alice, ref, "ghost")
    key = ghost.key
    assert_receive {:room_event, ^ref, {:message_failed, ^key, :vanished}}, 10_000
  end

  test "members joining via events are subscribed and backfilled", %{alice: alice, ref: ref} do
    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, _} = RoomServer.attach(ref)

    bob = Fixtures.z32("bob")
    {:ok, old} = Message.new(bob, ref, "bob was here")
    Fake.seed(bob, Message.path(old), Message.encode(old))
    Fake.write_as(bob, Paths.member(ref), PubkyRooms.Rooms.Membership.encode(ref))

    assert_receive {:room_event, ^ref, {:member_joined, ^bob}}, 1_000

    assert_receive {:room_event, ^ref, {:message_upserted, %Message{content: "bob was here"}}},
                   2_000

    assert Directory.member?(ref, bob)
    assert Rooms.member?(ref, alice)

    Fake.delete_as(bob, Paths.member(ref))
    assert_receive {:room_event, ^ref, {:member_left, ^bob}}, 1_000
    refute Directory.member?(ref, bob)
  end

  test "unknown rooms report not_found; closing the room broadcasts", %{alice: alice, ref: ref} do
    missing = {alice, "0000000000000"}
    Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(missing))
    {:ok, _} = RoomServer.ensure(missing)
    assert_receive {:room_event, ^missing, {:unavailable, :not_found}}, 2_000

    {:ok, _} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, _} = RoomServer.attach(ref)
    Fake.delete_as(alice, Paths.room(elem(ref, 1)))
    assert_receive {:room_event, ^ref, :room_closed}, 1_000
    assert Directory.get(ref) == nil
  end

  test "idle rooms stop and release their subscriptions", %{ref: ref} do
    {:ok, pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    mon = Process.monitor(pid)
    assert_receive {:DOWN, ^mon, :process, ^pid, :normal}, 2_000
    assert wait_until(fn -> RoomServer.whereis(ref) == nil end)
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end

defmodule PubkyRooms.Rooms.RoomServerTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Directory, Membership, Message, Paths, Room, RoomServer}

  setup do
    reset_state()
    {sid, alice} = Fixtures.login("alice")

    {:ok, room} =
      Rooms.create_room(sid, alice, %{"name" => "Test room", "visibility" => "public"})

    ref = Room.ref(room)
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

  test "bootstrap merges listings across members and keeps only the newest messages", ctx do
    %{alice: alice, ref: ref} = ctx
    bob = Fixtures.z32("bob")
    Directory.add_member(ref, bob)

    for {author, n} <- [{alice, 4}, {bob, 4}], i <- 1..n do
      {:ok, m} = Message.new(author, ref, "#{String.slice(author, 0, 4)} #{i}")
      Fake.seed(author, Message.path(m), Message.encode(m))
    end

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{table: table}} = RoomServer.attach(ref)
    history = RoomServer.history(table)

    # test config: bootstrap_messages = 5 → the 5 newest of the 8 seeded, in order
    assert length(history) == 5
    assert history == Enum.sort_by(history, & &1.msg_id)
    assert List.last(history).content =~ " 4"
    assert Enum.map(history, & &1.author) |> Enum.uniq() |> length() == 2
  end

  test "members whose homeserver cannot be listed are reported and retried", ctx do
    %{ref: ref} = ctx
    bob = Fixtures.z32("bob")
    Directory.add_member(ref, bob)
    {:ok, m} = Message.new(bob, ref, "bob history")
    Fake.seed(bob, Message.path(m), Message.encode(m))
    Fake.fail_list(bob, :unreachable)

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, snapshot} = RoomServer.attach(ref)
    assert snapshot.unreachable == [bob]
    assert RoomServer.history(snapshot.table) == []
    assert_received {:room_event, ^ref, {:unreachable, [^bob]}}

    RoomServer.retry_history(ref)

    assert_receive {:room_event, ^ref, {:message_upserted, %Message{content: "bob history"}}},
                   2_000

    assert_receive {:room_event, ^ref, {:unreachable, []}}, 2_000
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
    Fake.write_as(bob, Paths.member(ref), Membership.encode(ref))

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

  test "members over the live budget are polled instead of subscribed; nobody is dropped", ctx do
    %{alice: alice, ref: ref} = ctx
    Application.put_env(:pubky_rooms, :max_members_subscribed, 1)
    on_exit(fn -> Application.delete_env(:pubky_rooms, :max_members_subscribed) end)

    # members unique to this test, so no earlier test's subscription lingers
    bob = Fixtures.z32("budget-bob")
    Directory.add_member(ref, bob)

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, snapshot} = RoomServer.attach(ref)
    assert Enum.sort(snapshot.members) == Enum.sort([alice, bob])
    assert snapshot.polled == [bob]
    # the creator is subscribed (asynchronously), the polled member never is
    assert wait_until(fn -> Map.has_key?(Subscriptions.statuses([alice]), alice) end)
    assert Subscriptions.statuses([bob]) == %{}

    # a file that appears on bob's homeserver without an event reaching us is
    # picked up by the poll (test config: every 100 ms while viewers are attached)
    {:ok, m} = Message.new(bob, ref, "polled in")
    Fake.seed(bob, Message.path(m), Message.encode(m))
    assert_receive {:room_event, ^ref, {:message_upserted, %Message{content: "polled in"}}}, 2_000

    # a third member joining also lands in the polled set
    carol = Fixtures.z32("budget-carol")
    Directory.add_member(ref, carol)
    assert_receive {:room_event, ^ref, {:member_joined, ^carol}}, 1_000
    assert_receive {:room_event, ^ref, {:polled, polled}}, 1_000
    assert Enum.sort(polled) == Enum.sort([bob, carol])

    # leaving removes them from it
    Directory.remove_member(ref, carol)
    assert_receive {:room_event, ^ref, {:polled, [^bob]}}, 1_000
  end

  test "the viewer total is announced on the stats topic, debounced, signed in or not", ctx do
    %{ref: ref} = ctx
    Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.stats_topic(ref))
    assert RoomServer.viewer_count(ref) == 0

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{viewers: 0}} = RoomServer.snapshot(ref)

    # two viewers attach within one debounce window → a single announcement
    {:ok, %{viewers: 1}} = RoomServer.attach(ref)
    other = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, %{viewers: 2}} = RoomServer.attach(ref, other)
    assert_receive {:room_stats, ^ref, %{viewers: 2}}, 1_000
    refute_received {:room_stats, ^ref, %{viewers: 1}}
    assert RoomServer.viewer_count(ref) == 2

    Process.exit(other, :kill)
    assert_receive {:room_stats, ^ref, %{viewers: 1}}, 1_000
  end

  test "a member without a message folder yet is not reported as unreachable", ctx do
    %{ref: ref} = ctx
    newcomer = Fixtures.z32("newcomer")
    Directory.add_member(ref, newcomer)

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{unreachable: [], members: members}} = RoomServer.attach(ref)
    assert newcomer in members

    # …and neither is one who joins live
    later = Fixtures.z32("later")
    Directory.add_member(ref, later)
    assert_receive {:room_event, ^ref, {:member_joined, ^later}}, 1_000
    refute_receive {:room_event, ^ref, {:unreachable, _}}, 300
  end

  test "members whose live stream is down are reported and cleared when it recovers", ctx do
    %{alice: alice, ref: ref} = ctx
    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000

    Phoenix.PubSub.broadcast(
      PubkyRooms.PubSub,
      "subscriptions",
      {:subscription_status, alice, {:error, :boom}}
    )

    assert_receive {:room_event, ^ref, {:live_unavailable, [^alice]}}, 1_000
    {:ok, %{live_unavailable: [^alice]}} = RoomServer.snapshot(ref)

    Phoenix.PubSub.broadcast(
      PubkyRooms.PubSub,
      "subscriptions",
      {:subscription_status, alice, :attached}
    )

    assert_receive {:room_event, ^ref, {:live_unavailable, []}}, 1_000

    # statuses of users that are not subscribed members are ignored
    stranger = Fixtures.z32("stranger")

    Phoenix.PubSub.broadcast(
      PubkyRooms.PubSub,
      "subscriptions",
      {:subscription_status, stranger, {:error, :boom}}
    )

    refute_receive {:room_event, ^ref, {:live_unavailable, _}}, 200
  end
end

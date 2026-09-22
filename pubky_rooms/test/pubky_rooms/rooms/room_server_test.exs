defmodule PubkyRooms.Rooms.RoomServerTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Ban, Directory, Membership, Message, Paths, Reaction, Room, RoomServer}

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

    {:ok, pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, _} = RoomServer.attach(ref)
    Fake.delete_as(alice, Paths.room(elem(ref, 1)))
    assert_receive {:room_event, ^ref, :room_closed}, 1_000

    # the directory keeps the room as a closed archive and the server stays up
    assert %Room{closed_at: closed_at} = Directory.get(ref)
    assert is_integer(closed_at)
    assert Process.alive?(pid)

    assert {:ok, %{status: :closed, room: %Room{closed_at: ^closed_at}}} =
             RoomServer.snapshot(ref)
  end

  test "a closed room bootstraps as a read-only archive from the members' folders and reopens when the definition returns",
       %{alice: alice, ref: ref, room: room} do
    {bob_sid, bob} = Fixtures.login("bob")
    :ok = Rooms.join(bob_sid, bob, ref)
    {:ok, m1} = Message.new(bob, ref, "bob was here")
    Fake.seed(bob, Message.path(m1), Message.encode(m1))

    # the creator deletes the definition while nobody has the room open
    Directory.subscribe()
    Fake.delete_as(alice, Paths.room(room.id))
    assert_receive {:directory, {:room_closed, %Room{closed_at: closed_at}}}, 1_000
    assert %Room{closed_at: ^closed_at} = Directory.get(ref)
    assert bob in Directory.members_of(ref)

    {:ok, pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, snapshot} = RoomServer.attach(ref)
    assert %{status: :closed, room: %Room{name: "Test room", closed_at: ^closed_at}} = snapshot
    assert [%Message{content: "bob was here"}] = RoomServer.history(snapshot.table)
    assert bob in snapshot.members

    # members' own homeserver changes still apply to the archive
    Fake.delete_as(bob, Message.path(m1))
    key = m1.key
    assert_receive {:room_event, ^ref, {:message_deleted, ^key}}, 1_000

    # writing the definition again reopens the room for everyone
    Fake.write_as(alice, Paths.room(room.id), Room.encode(room))
    assert_receive {:room_event, ^ref, :ready}, 2_000
    assert {:ok, %{status: :ready, room: %Room{closed_at: nil}}} = RoomServer.snapshot(ref)
    assert %Room{closed_at: nil} = Directory.get(ref)
    assert Process.alive?(pid)
  end

  test "a room the directory never knew is not_found when its definition is missing", %{
    alice: alice
  } do
    missing = {alice, "0000000000002"}
    Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(missing))
    {:ok, _} = RoomServer.ensure(missing)
    assert_receive {:room_event, ^missing, {:unavailable, :not_found}}, 2_000
    assert Directory.get(missing) == nil
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

  test "polls are exact: pages of new messages are all picked up and silent deletions are noticed",
       ctx do
    %{ref: ref} = ctx
    Application.put_env(:pubky_rooms, :max_members_subscribed, 1)
    on_exit(fn -> Application.delete_env(:pubky_rooms, :max_members_subscribed) end)
    bob = Fixtures.z32("exact-bob")
    Directory.add_member(ref, bob)

    # bob already has one message when the room opens
    {:ok, first} = Message.new(bob, ref, "exact 0")
    Fake.seed(bob, Message.path(first), Message.encode(first))
    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{table: table, polled: [^bob]}} = RoomServer.attach(ref)
    assert [%Message{content: "exact 0"}] = RoomServer.history(table)

    # 25 files appear without any event reaching us: three listing pages
    # (bootstrap_per_member is 10 in tests) and far more than the bootstrap
    # fetch cap (bootstrap_messages 5); a poll must fetch every one of them
    msgs =
      for i <- 1..25 do
        {:ok, m} = Message.new(bob, ref, "exact #{i}")
        Fake.seed(bob, Message.path(m), Message.encode(m))
        m
      end

    for %Message{content: content} <- msgs do
      assert_receive {:room_event, ^ref, {:message_upserted, %Message{content: ^content}}}, 3_000
    end

    assert length(RoomServer.history(table)) == 26

    # a file among the member's newest page removed without an event is
    # noticed once it is older than one poll interval; older deletions wait
    # for the next bootstrap (the poll stops at the first message it knows)
    gone = Enum.at(msgs, 19)
    Fake.unseed(bob, Message.path(gone))
    key = gone.key
    assert_receive {:room_event, ^ref, {:message_deleted, ^key}}, 3_000
    refute Enum.any?(RoomServer.history(table), &(&1.key == key))
    assert length(RoomServer.history(table)) == 25
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

  test "older/3 pages the whole history in order across members, then reports no more", ctx do
    %{alice: alice, ref: ref} = ctx
    bob = Fixtures.z32("pager-bob")
    Directory.add_member(ref, bob)

    # test config: bootstrap lists 10 per member and fetches the newest 5 overall;
    # alice has more than one listing page, bob has one short page
    seeded =
      for {author, n} <- [{alice, 12}, {bob, 8}], i <- 1..n do
        {:ok, m} = Message.new(author, ref, "#{String.slice(author, 0, 4)} #{i}")
        Fake.seed(author, Message.path(m), Message.encode(m))
        m.key
      end

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{table: table, more?: true}} = RoomServer.attach(ref)
    first = RoomServer.history(table)
    assert length(first) == 5
    drain_mailbox()

    pages = page_back(ref, hd(first).key, [])
    all = Enum.concat(pages) ++ first
    assert Enum.map(all, & &1.key) == Enum.sort(seeded)
    assert length(all) == 20

    # paging is silent: no broadcasts for old messages
    refute_received {:room_event, ^ref, {:message_upserted, _}}

    # a brand-new message still arrives live and the window is complete below it
    {:ok, m} = Message.new(bob, ref, "newest")
    Fake.write_as(bob, Message.path(m), Message.encode(m))
    assert_receive {:room_event, ^ref, {:message_upserted, %Message{content: "newest"}}}, 1_000
    assert {:ok, [], false} = RoomServer.older(ref, hd(all).key, 5)
  end

  defp drain_mailbox do
    receive do
      _ -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  defp page_back(ref, before, acc) do
    case RoomServer.older(ref, before, 5) do
      {:ok, [], false} ->
        acc

      {:ok, msgs, more?} ->
        assert msgs == Enum.sort_by(msgs, & &1.key)
        assert List.last(msgs).key < before
        if more?, do: page_back(ref, hd(msgs).key, [msgs | acc]), else: [msgs | acc]
    end
  end

  test "reactions are restored from listings and toggled by events without any fetch", ctx do
    %{alice: alice, ref: ref, sid: sid} = ctx
    {bob_sid, bob} = Fixtures.login("react-bob")
    Directory.add_member(ref, bob)

    {:ok, m} = Message.new(alice, ref, "react to me")
    Fake.seed(alice, Message.path(m), Message.encode(m))
    Fake.seed(bob, Paths.reaction(ref, alice, m.msg_id, "up"), Reaction.encode())
    # a marker for a message that is not loaded is kept aside until it is
    Fake.seed(bob, Paths.reaction(ref, alice, "0000000000000", "fire"), Reaction.encode())

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{table: table}} = RoomServer.attach(ref)
    [%Message{reactions: reactions}] = RoomServer.history(table)
    assert reactions == %{"up" => MapSet.new([bob])}
    drain_mailbox()

    # alice reacts (writes a marker): the event updates the row and is broadcast
    assert :ok = Rooms.react(sid, m, "up")
    assert_receive {:room_event, ^ref, {:message_upserted, %Message{reactions: r1}}}, 1_000
    assert r1["up"] == MapSet.new([alice, bob])

    assert :ok = Rooms.react(sid, m, "heart")
    assert_receive {:room_event, ^ref, {:message_upserted, %Message{reactions: r2}}}, 1_000
    assert Map.keys(r2) |> Enum.sort() == ["heart", "up"]

    # bob withdraws
    assert :ok = Rooms.unreact(bob_sid, m, "up")
    assert_receive {:room_event, ^ref, {:message_upserted, %Message{reactions: r3}}}, 1_000
    assert r3["up"] == MapSet.new([alice])

    # only the palette is written; a stranger's marker is ignored
    assert {:error, :invalid_reaction} = Rooms.react(sid, m, "nope")
    stranger = Fixtures.z32("react-stranger")
    Fake.write_as(stranger, Paths.reaction(ref, alice, m.msg_id, "up"), Reaction.encode())
    refute_receive {:room_event, ^ref, {:message_upserted, _}}, 200

    # an edit keeps the reactions
    Fake.write_as(alice, Message.path(m), Message.encode(%{m | content: "edited", edited_at: 1}))

    assert_receive {:room_event, ^ref,
                    {:message_upserted, %Message{content: "edited", reactions: r4}}},
                   1_000

    assert r4 == r3
  end

  test "bans from the creator's homeserver hide a member; lifting the ban restores them", ctx do
    %{alice: alice, ref: ref, sid: sid} = ctx
    {bob_sid, bob} = Fixtures.login("ban-bob")
    Directory.add_member(ref, bob)
    {:ok, old} = Message.new(bob, ref, "bob before")
    Fake.seed(bob, Message.path(old), Message.encode(old))
    Fake.seed(bob, Paths.reaction(ref, alice, "0035PG0000000", "up"), Reaction.encode())
    # a marker on someone else's homeserver is not a ban
    Fake.seed(bob, Paths.ban(elem(ref, 1), alice), Ban.encode("nope"))
    # a real one, already there at bootstrap
    Fake.seed(alice, Paths.ban(elem(ref, 1), bob), Ban.encode("spam"))

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    {:ok, %{table: table, bans: bans, members: members}} = RoomServer.attach(ref)
    assert bans == %{bob => "spam"}
    assert bob in members
    assert RoomServer.history(table) == []
    drain_mailbox()

    # while banned, bob's writes are ignored
    {:ok, ignored} = Message.new(bob, ref, "still banned")
    Fake.write_as(bob, Message.path(ignored), Message.encode(ignored))
    refute_receive {:room_event, ^ref, {:message_upserted, _}}, 200

    # lifting the ban restores bob's history
    assert :ok = Rooms.unban(sid, alice, ref, bob)
    assert_receive {:room_event, ^ref, {:member_unbanned, ^bob}}, 1_000

    assert_receive {:room_event, ^ref, {:message_upserted, %Message{content: "bob before"}}},
                   2_000

    assert_receive {:room_event, ^ref, {:message_upserted, %Message{content: "still banned"}}},
                   2_000

    {:ok, %{bans: %{}}} = RoomServer.snapshot(ref)

    # banning live removes the messages and announces the reason once it is read
    assert {:error, :forbidden} = Rooms.ban(bob_sid, bob, ref, alice, nil)
    assert {:error, :forbidden} = Rooms.ban(sid, alice, ref, alice, nil)
    assert :ok = Rooms.ban(sid, alice, ref, bob, "  too loud  ")
    assert_receive {:room_event, ^ref, {:member_banned, ^bob, _}}, 1_000
    key1 = old.key
    key2 = ignored.key
    assert_receive {:room_event, ^ref, {:message_deleted, ^key1}}, 1_000
    assert_receive {:room_event, ^ref, {:message_deleted, ^key2}}, 1_000

    assert wait_until(fn ->
             match?({:ok, %{bans: %{^bob => "too loud"}}}, RoomServer.snapshot(ref))
           end)

    assert RoomServer.history(table) == []
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

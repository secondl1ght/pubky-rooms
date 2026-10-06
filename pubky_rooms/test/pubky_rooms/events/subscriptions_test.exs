defmodule PubkyRooms.Events.SubscriptionsTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.Events.{Cursors, Subscriptions}
  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Room, RoomServer}

  # test config: detach grace and retry delay are 100 ms

  setup do
    reset_state()
    Subscriptions.subscribe()
    # users acquired by earlier tests (their LiveViews and room servers are
    # gone) detach within the grace period; start from a quiet state
    assert wait_until(fn -> Subscriptions.info() == %{users: %{}, streams: %{}} end, 200),
           "subscriptions still busy: #{inspect(Subscriptions.info())}"

    :ok
  end

  test "acquiring a user attaches them to a stream and announces the status" do
    user = Fixtures.z32("sub")
    Subscriptions.acquire([user], self())
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    assert Subscriptions.status(user) == :attached
    assert Subscriptions.statuses([user, "unknown"]) == %{user => :attached}
    assert user in Fake.stream_users()

    # a stream disconnect marks its users; a reconnect clears them
    %{users: %{^user => %{stream: {hs, name}}}} = Subscriptions.info()
    send(Subscriptions, {:pubky_stream, {hs, name}, {:disconnected, :idle}})
    assert_receive {:subscription_status, ^user, {:error, {:disconnected, :idle}}}, 1_000
    send(Subscriptions, {:pubky_stream, {hs, name}, :connected})
    assert_receive {:subscription_status, ^user, :attached}, 1_000

    Subscriptions.release([user], self())
  end

  test "a throttled stream connect is logged with its delay and clears on reconnect" do
    user = Fixtures.z32("throttled")
    Subscriptions.acquire([user], self())
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    %{users: %{^user => %{stream: {hs, name}}}} = Subscriptions.info()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(Subscriptions, {:pubky_stream, {hs, name}, {:disconnected, {:rate_limited, 3_000}}})

        assert_receive {:subscription_status, ^user,
                        {:error, {:disconnected, {:rate_limited, 3_000}}}},
                       1_000
      end)

    assert log =~ "throttled by the homeserver (429), retrying in 3000 ms"
    # a warning names the stream, never its homeserver (ADR 0006: keys at debug only)
    assert log =~ inspect(name)
    refute log =~ String.slice(hs, 0, 8)

    send(Subscriptions, {:pubky_stream, {hs, name}, :connected})
    assert_receive {:subscription_status, ^user, :attached}, 1_000
    Subscriptions.release([user], self())
  end

  test "owners are reference-counted; the last release detaches after the grace period" do
    user = Fixtures.z32("refcount")
    other = spawn(fn -> Process.sleep(:infinity) end)

    Subscriptions.acquire([user], self())
    Subscriptions.acquire([user], other)
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    assert %{users: %{^user => %{owners: 2}}} = Subscriptions.info()

    Subscriptions.release([user], other)
    Process.sleep(250)
    assert Subscriptions.status(user) == :attached
    assert user in Fake.stream_users()

    # releasing the last owner and re-acquiring within the grace keeps the subscription
    Subscriptions.release([user], self())
    Subscriptions.acquire([user], self())
    Process.sleep(250)
    assert Subscriptions.status(user) == :attached

    Subscriptions.release([user], self())
    assert wait_until(fn -> Subscriptions.status(user) == nil end)
    refute user in Fake.stream_users()
    Process.exit(other, :kill)
  end

  test "an owner dying releases its users; an empty stream is stopped" do
    user = Fixtures.z32("down")
    owner = spawn(fn -> Process.sleep(:infinity) end)
    Subscriptions.acquire([user], owner)
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    [stream] = Fake.live_streams()

    Process.exit(owner, :kill)
    assert wait_until(fn -> Subscriptions.status(user) == nil end)
    assert wait_until(fn -> not Process.alive?(stream) end)
    assert Subscriptions.info().streams == %{}
  end

  test "streams are sharded at 50 users per homeserver" do
    users = for i <- 1..51, do: Fixtures.z32("shard-#{i}")
    Subscriptions.acquire(users, self())
    for u <- users, do: assert_receive({:subscription_status, ^u, :attached}, 5_000)

    %{streams: streams} = Subscriptions.info()
    sizes = streams |> Map.values() |> Enum.map(&length/1) |> Enum.sort()
    assert sizes == [1, 50]
    assert streams |> Map.values() |> List.flatten() |> Enum.sort() == Enum.sort(users)
    Subscriptions.release(users, self())
  end

  test "a failed resolution is reported and retried until it succeeds" do
    user = Fixtures.z32("flaky")
    Fake.fail_resolve(user, :unreachable)
    Subscriptions.acquire([user], self())
    assert_receive {:subscription_status, ^user, {:error, :unreachable}}, 2_000
    assert Subscriptions.status(user) == {:error, :unreachable}

    # the retry (100 ms in tests) finds the homeserver reachable again
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    assert user in Fake.stream_users()
    Subscriptions.release([user], self())
  end

  test "a stream process dying marks its users, who are re-attached on a new stream" do
    user = Fixtures.z32("crashy")
    Subscriptions.acquire([user], self())
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    # streams of other tests' stragglers may coexist: follow this user's stream
    stream = Fake.stream_of(user)
    assert is_pid(stream)

    Process.exit(stream, :kill)
    # once in ~10 full runs the DOWN reason arrives as :noproc instead of
    # :killed; either way the user is re-attached
    assert_receive {:subscription_status, ^user, {:error, reason}}, 2_000
    assert reason in [:killed, :noproc]
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    new_stream = Fake.stream_of(user)
    assert is_pid(new_stream)
    assert new_stream != stream
    Subscriptions.release([user], self())
  end

  test "a stream reconnecting to apply a changed user list is not an outage" do
    user = Fixtures.z32("resub")
    Subscriptions.acquire([user], self())
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    %{users: %{^user => %{stream: key}}} = Subscriptions.info()

    send(Subscriptions, {:pubky_stream, key, {:disconnected, :resubscribe}})
    refute_receive {:subscription_status, ^user, _}, 200
    assert Subscriptions.status(user) == :attached

    send(Subscriptions, {:pubky_stream, key, {:disconnected, :closed}})
    assert_receive {:subscription_status, ^user, {:error, {:disconnected, :closed}}}, 1_000
    Subscriptions.release([user], self())
  end

  test "a call into a stream that just died does not take the process down" do
    user = Fixtures.z32("dying-a")
    other = Fixtures.z32("dying-b")
    Subscriptions.acquire([user], self())
    assert_receive {:subscription_status, ^user, :attached}, 2_000
    stream = Fake.stream_of(user)
    server = Process.whereis(Subscriptions)

    # kill the stream and add a second user to it in the same breath: whichever
    # message the server sees first, it survives and both end up attached
    Process.exit(stream, :kill)
    Subscriptions.acquire([other], self())
    assert_receive {:subscription_status, ^other, :attached}, 3_000
    assert_receive {:subscription_status, ^user, :attached}, 3_000
    assert Process.whereis(Subscriptions) == server
    Subscriptions.release([user, other], self())
  end

  test "a restarted subscriptions process starts afresh and room servers acquire again" do
    {sid, alice} = Fixtures.login("alice")

    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "R", "visibility" => "public"})
    ref = Room.ref(room)
    Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(ref))
    {:ok, room_pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000
    assert_receive {:subscription_status, ^alice, :attached}, 2_000
    old_stream = Fake.stream_of(alice)

    Process.exit(Process.whereis(Subscriptions), :kill)
    assert wait_until(fn -> is_pid(Process.whereis(Subscriptions)) end)

    # the old stream is gone, the room re-acquired its member on a new one
    assert_receive {:subscription_status, ^alice, :attached}, 3_000
    refute Process.alive?(old_stream)
    assert Fake.stream_of(alice) != old_stream
    assert Process.alive?(room_pid)
    Process.exit(room_pid, :normal)
  end

  test "capture_cursor records the current cursor once and keeps it" do
    user = Fixtures.z32("cursor")
    assert {:ok, nil} = Subscriptions.capture_cursor(user)
    Fake.write_as(user, "/pub/pubky-rooms/profile.json", ~s({"v":1,"name":"x"}))
    # the write advanced the fake cursor; the captured value stays what it was
    assert {:ok, captured} = Subscriptions.capture_cursor(user)
    assert captured == Cursors.get(user)
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end

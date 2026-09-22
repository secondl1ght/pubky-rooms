defmodule PubkyRooms.TelemetryTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.{Fixtures, Rooms, Telemetry}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Message, Room, RoomServer}

  @events [
    [:pubky_rooms, :stream, :connected],
    [:pubky_rooms, :stream, :disconnected],
    [:pubky_rooms, :stream, :unavailable],
    [:pubky_rooms, :room, :bootstrap],
    [:pubky_rooms, :message, :confirm],
    [:pubky_rooms, :message, :lag],
    [:pubky_rooms, :capacity]
  ]

  setup do
    reset_state()
    handler = :telemetry_test.attach_event_handlers(self(), @events)
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "rooms report bootstrap, confirmations and event lag as durations and counts only" do
    {sid, alice} = Fixtures.login("alice")
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Metrics", "visibility" => "public"})
    ref = Room.ref(room)
    Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(ref))

    {:ok, _} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 2_000

    assert_receive {[:pubky_rooms, :room, :bootstrap], _ref,
                    %{duration: d, members: 1, messages: 0}, %{status: :ready}}

    assert is_integer(d) and d >= 0

    # a write from this node: registered, then confirmed by its own event
    {:ok, msg} = Rooms.prepare_message(sid, alice, ref, "measured")
    :ok = Rooms.publish_message(sid, msg)

    assert_receive {[:pubky_rooms, :message, :confirm], _ref, %{duration: ms}, %{via: :event}},
                   1_000

    assert is_integer(ms) and ms >= 0

    # a write from another client: fetched, and its age reported as lag
    {:ok, other} = Message.new(alice, ref, "from elsewhere")
    Fake.write_as(alice, Message.path(other), Message.encode(other))
    assert_receive {[:pubky_rooms, :message, :lag], _ref, %{duration: lag}, %{}}, 1_000
    assert is_integer(lag) and lag >= 0

    # nothing that was emitted names a key, a room or content
    refute_identifiers()
  end

  test "stream status changes and failed attaches are counted with a bounded reason tag" do
    hs = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
    send(Subscriptions, {:pubky_stream, {hs, {:rooms, 0, 1}}, :connected})
    assert_receive {[:pubky_rooms, :stream, :connected], _ref, %{count: 1}, %{}}, 1_000

    send(Subscriptions, {:pubky_stream, {hs, {:rooms, 0, 1}}, {:disconnected, {:http, 500}}})

    assert_receive {[:pubky_rooms, :stream, :disconnected], _ref, %{count: 1}, %{reason: :http}},
                   1_000

    user = Fixtures.z32("unresolvable")
    Fake.fail_resolve(user, :not_found)
    Subscriptions.acquire([user], self())

    assert_receive {[:pubky_rooms, :stream, :unavailable], _ref, %{count: 1},
                    %{reason: :not_found}},
                   2_000

    Subscriptions.release([user], self())
    refute_identifiers()
  end

  test "capacity readings and health are counts; the poller emits them" do
    assert %{streams: s, users: u, pool_size: pool, rooms: r} = Telemetry.capacity()
    assert is_integer(s) and is_integer(u) and is_integer(r)
    assert pool == Telemetry.pool_size()

    Telemetry.measure()
    assert_receive {[:pubky_rooms, :capacity], _ref, %{streams: ^s, pool_size: ^pool}, %{}}

    assert {:ok, %{status: "ok", streams: ^s, stream_pool: ^pool, rooms: ^r}} = Telemetry.health()
  end

  test "reason tags never carry structure" do
    assert Telemetry.reason_tag(:not_found) == :not_found
    assert Telemetry.reason_tag({:relay, "http://somewhere"}) == :relay
    assert Telemetry.reason_tag({:http, 429, "body"}) == :http
    assert Telemetry.reason_tag("a string") == :other
  end

  # Metadata and measurements must be free of anything resembling a public key.
  defp refute_identifiers do
    {:messages, msgs} = Process.info(self(), :messages)

    for {[:pubky_rooms | _], _ref, measurements, metadata} <- msgs,
        value <- Map.values(measurements) ++ Map.values(metadata) do
      refute is_binary(value) and String.length(value) == 52,
             "a public key leaked into telemetry: #{inspect(value)}"

      refute is_tuple(value) or is_map(value) or is_list(value),
             "structured metadata in telemetry: #{inspect(value)}"
    end
  end
end

defmodule PubkyRooms.Integration.AppTestnetTest do
  @moduledoc """
  The whole app against a local pubky-docker testnet: real homeserver, real
  PKARR relay, real SSE streams, real sessions — only Pubky Ring is replaced by
  `Pubky.Auth.LocalSigner`.

      docker compose up homeserver -d   # in a pubky-docker checkout
      mix test --include testnet test/integration
  """
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :testnet
  @moduletag timeout: 120_000

  alias Pubky.Auth.{Capability, LocalSigner}
  alias Pubky.{Config, Keypair}
  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Rooms
  alias PubkyRooms.Rooms.{Message, Room, RoomServer}

  setup do
    reset_state()
    Application.put_env(:pubky_rooms, :pubky_backend, PubkyRooms.Pubky.Live)
    on_exit(fn -> Application.put_env(:pubky_rooms, :pubky_backend, PubkyRooms.Pubky.Fake) end)
    Pubky.Resolver.clear()
    :ok
  end

  # A fresh identity on the testnet homeserver, signed in with exactly the
  # capability Pubky Ring would grant Rooms.
  defp identity do
    config = Config.get()
    hs = Config.testnet_homeserver()
    kp = Keypair.generate()
    :ok = LocalSigner.signup(kp, hs, [], config)
    {:ok, cap} = Capability.read_write("/pub/pubky-rooms/")
    {:ok, session} = LocalSigner.signin(kp, hs, [caps: [cap]], config)
    {SessionStore.put(session), Keypair.public_z32(kp)}
  end

  test "sign in, create, send, confirm by event, second member live, restart, delete", %{
    conn: conn
  } do
    {alice_sid, alice} = identity()
    {bob_sid, bob} = identity()

    {:ok, room} =
      Rooms.create_room(alice_sid, alice, %{
        "name" => "Testnet e2e",
        "visibility" => "public",
        "tags" => "e2e"
      })

    ref = Room.ref(room)
    Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(ref))

    # proof this went to the real homeserver: the definition is a public file there
    assert {:ok, %Req.Response{status: 200, body: body}} =
             Req.get("http://localhost:6286/pub/pubky-rooms/rooms/#{room.id}",
               headers: [{"pubky-host", alice}],
               decode_body: false,
               retry: false
             )

    assert body =~ "Testnet e2e"

    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 30_000
    {:ok, %{members: members}} = RoomServer.attach(ref)
    assert alice in members

    # a message is confirmed by alice's homeserver announcing it over SSE
    {:ok, msg} = Rooms.prepare_message(alice_sid, alice, ref, "hello testnet")
    assert :ok = Rooms.publish_message(alice_sid, msg)

    assert_receive {:room_event, ^ref,
                    {:message_upserted, %Message{content: "hello testnet", state: :confirmed}}},
                   30_000

    # bob joins (marker on his homeserver) and his message arrives through his stream
    assert :ok = Rooms.join(bob_sid, bob, ref)
    assert_receive {:room_event, ^ref, {:member_joined, ^bob}}, 10_000
    {:ok, reply} = Rooms.prepare_message(bob_sid, bob, ref, "bob on testnet", reply_to: msg.uri)
    assert :ok = Rooms.publish_message(bob_sid, reply)

    assert_receive {:room_event, ^ref,
                    {:message_upserted, %Message{content: "bob on testnet", state: :confirmed}}},
                   30_000

    # a reaction rides the path alone
    assert :ok = Rooms.react(bob_sid, msg, "fire")

    assert_receive {:room_event, ^ref,
                    {:message_upserted,
                     %Message{content: "hello testnet", reactions: %{"fire" => reactors}}}},
                   30_000

    assert bob in reactors

    # the LiveView renders it all for a signed-in browser
    conn = init_test_session(conn, SessionStore.cookie_session(alice_sid))
    {:ok, view, _} = live(conn, ~p"/r/#{alice}/#{room.id}")
    html = wait_for(fn -> render(view) end, &(&1 =~ "bob on testnet"))
    assert html =~ "hello testnet"
    assert html =~ "fire · 1"
    assert html =~ "e2e"
    GenServer.stop(view.pid)

    # restart: the room is rebuilt from the homeservers alone
    RoomServer.whereis(ref) |> Process.exit(:kill)
    Process.sleep(200)
    {:ok, _pid} = RoomServer.ensure(ref)
    assert_receive {:room_event, ^ref, :ready}, 30_000
    {:ok, %{table: table}} = RoomServer.attach(ref)
    contents = table |> RoomServer.history() |> Enum.map(& &1.content)
    assert contents == ["hello testnet", "bob on testnet"]
    [first | _] = RoomServer.history(table)
    assert first.reactions == %{"fire" => MapSet.new([bob])}

    # delete propagates as a DEL event
    assert :ok = Rooms.delete_message(bob_sid, reply)
    key = reply.key
    assert_receive {:room_event, ^ref, {:message_deleted, ^key}}, 30_000

    # close the room: definition gone, viewers told
    assert :ok = Rooms.close_room(alice_sid, alice, room)
    assert_receive {:room_event, ^ref, :room_closed}, 30_000
  end

  defp wait_for(fun, pred, tries \\ 250) do
    value = fun.()

    cond do
      pred.(value) -> value
      tries == 0 -> flunk("condition not met; last value: #{inspect(value, limit: 300)}")
      true -> Process.sleep(40) && wait_for(fun, pred, tries - 1)
    end
  end
end

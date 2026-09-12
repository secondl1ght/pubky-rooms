defmodule PubkyRoomsWeb.RoomLiveTest do
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  import Phoenix.LiveViewTest

  alias PubkyRooms.{Fixtures, Profiles, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Message, Paths, Room, RoomServer}

  setup %{conn: conn} do
    reset_state()
    {sid, alice} = Fixtures.login("alice")
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Slice", "visibility" => "public"})

    %{
      conn: conn,
      alice_conn: init_test_session(conn, Fixtures.cookie(sid)),
      alice: alice,
      room: room,
      path: ~p"/r/#{alice}/#{room.id}"
    }
  end

  test "invalid room links go back to the lobby", %{conn: conn, alice: alice} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/r/#{alice}/not-an-id")
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/r/nope/0000000000001")
  end

  test "the creator sends a message that is confirmed by the homeserver event", ctx do
    {:ok, view, _html} = live(ctx.alice_conn, ctx.path)
    assert render(view) =~ "No messages yet"
    assert has_element?(view, "#composer")

    view |> form("#composer", message: %{content: "hello sovereign world"}) |> render_submit()

    # the fake homeserver confirms synchronously inside the async publish
    render_async(view)
    html = wait_for(fn -> render(view) end, &(&1 =~ "Stored on your homeserver"))
    assert html =~ "hello sovereign world"
    refute html =~ "Sending to your homeserver"

    assert [%Message{content: "hello sovereign world"}] =
             messages_on_homeserver(ctx.alice, ctx.room)

    # blank messages are rejected before any write
    view |> form("#composer", message: %{content: "   "}) |> render_submit()
    assert render(view) =~ "can&#39;t be blank"
  end

  test "a failed write is shown with retry and discard", ctx do
    {:ok, view, _html} = live(ctx.alice_conn, ctx.path)
    Fake.fail_next_under(Paths.messages_dir(Room.ref(ctx.room)), :quota)

    view |> form("#composer", message: %{content: "will not land"}) |> render_submit()
    render_async(view)
    html = wait_for(fn -> render(view) end, &(&1 =~ "out of storage"))
    assert html =~ "Retry"

    view |> element("button", "Discard") |> render_click()
    refute render(view) =~ "will not land"
  end

  test "another viewer sees messages live; anonymous visitors are read-only", ctx do
    {:ok, anon, html} = live(ctx.conn, ctx.path)
    assert html =~ "Sign in with Pubky Ring to chat"
    refute has_element?(anon, "#composer")

    {:ok, alice, _} = live(ctx.alice_conn, ctx.path)
    alice |> form("#composer", message: %{content: "visible to everyone"}) |> render_submit()
    render_async(alice)

    assert wait_for(fn -> render(anon) end, &(&1 =~ "visible to everyone"))
  end

  test "a signed-in non-member joins and can then chat; the creator sees the join", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    {:ok, creator_view, _} = live(ctx.alice_conn, ctx.path)
    {:ok, bob_view, html} = live(bob_conn, ctx.path)
    assert html =~ "Join room"

    bob_view |> element("button", "Join room") |> render_click()
    render_async(bob_view)
    assert wait_for(fn -> render(bob_view) end, &has_composer?/1)
    assert Map.has_key?(Fake.files(bob), Paths.member(Room.ref(ctx.room)))

    assert wait_for(fn -> render(creator_view) end, &(&1 =~ "Members · 2"))

    bob_view |> form("#composer", message: %{content: "bob here"}) |> render_submit()
    render_async(bob_view)
    assert wait_for(fn -> render(creator_view) end, &(&1 =~ "bob here"))
  end

  test "a crashed room server is restarted and the view re-attaches", ctx do
    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    view |> form("#composer", message: %{content: "before the crash"}) |> render_submit()
    render_async(view)
    wait_for(fn -> render(view) end, &(&1 =~ "Stored on your homeserver"))

    old_pid = RoomServer.whereis(Room.ref(ctx.room))
    Process.exit(old_pid, :kill)

    html = wait_for(fn -> render(view) end, &(&1 =~ "before the crash"))

    new_pid =
      wait_for(
        fn -> RoomServer.whereis(Room.ref(ctx.room)) end,
        &(&1 != nil and &1 != old_pid)
      )

    assert Process.alive?(new_pid)
    assert html =~ "Stored on your homeserver"

    view |> form("#composer", message: %{content: "after the crash"}) |> render_submit()
    render_async(view)
    assert wait_for(fn -> render(view) end, &(&1 =~ "after the crash"))
  end

  test "presence counts signed-in viewers only; typing is shown to others and cleared on send",
       ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    PubkyRooms.Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    {:ok, _anon, _} = live(ctx.conn, ctx.path)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "1 online"))

    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "2 online"))
    assert wait_for(fn -> render(bob_view) end, &(&1 =~ "2 online"))
    assert PubkyRooms.Rooms.online_count(Room.ref(ctx.room)) == 2

    # the lobby-wide count includes both as well
    assert PubkyRoomsWeb.Presence.online_count(PubkyRoomsWeb.Presence.lobby_topic()) == 2

    # typing: bob's composer reports keystrokes; alice sees it, bob does not see himself
    render_hook(bob_view, "typing", %{})
    bob_name = Profiles.short_key(bob)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "#{bob_name} is typing"))
    refute render(bob_view) =~ "is typing"

    # sending clears it right away for everyone
    bob_view |> form("#composer", message: %{content: "done typing"}) |> render_submit()
    render_async(bob_view)
    html = wait_for(fn -> render(alice_view) end, &(&1 =~ "done typing"))
    refute html =~ "is typing"

    # a typing signal expires on its own
    render_hook(bob_view, "typing", %{})
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "is typing"))
    send(alice_view.pid, {:typing, bob, false})
    refute wait_for(fn -> render(alice_view) end, &(not (&1 =~ "is typing"))) =~ "is typing"

    # leaving drops bob from the online count
    GenServer.stop(bob_view.pid)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "1 online"))
  end

  test "names update in place when a profile changes, including on existing messages", ctx do
    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    view |> form("#composer", message: %{content: "who am I"}) |> render_submit()
    render_async(view)
    wait_for(fn -> render(view) end, &(&1 =~ "who am I"))
    assert render(view) =~ Profiles.short_key(ctx.alice)

    Fake.seed(ctx.alice, Profiles.pubky_app_profile_path(), JSON.encode!(%{name: "Alice Prime"}))
    Profiles.refresh(ctx.alice)

    html = wait_for(fn -> render(view) end, &(&1 =~ "Alice Prime"))
    # the message row (a stream item) shows the new name too
    assert html =~ ~r/msg-#{ctx.alice}-[0-9A-Z]+.*Alice Prime/s

    refute html =~
             ~r/<article[^>]*>.*#{Regex.escape(Profiles.short_key(ctx.alice))}.*<\/article>/s
  end

  defp has_composer?(html), do: html =~ ~s(id="composer")

  defp messages_on_homeserver(user, room) do
    ref = Room.ref(room)

    for {path, bytes} <- Fake.files(user),
        {:message, _, _, msg_id} <- [Paths.parse(path)],
        {:ok, msg} <- [Message.decode(bytes, user, ref, msg_id)],
        do: msg
  end

  defp wait_for(fun, pred, tries \\ 50) do
    value = fun.()

    cond do
      pred.(value) -> value
      tries == 0 -> flunk("condition not met; last value: #{inspect(value, limit: 300)}")
      true -> Process.sleep(20) && wait_for(fun, pred, tries - 1)
    end
  end
end

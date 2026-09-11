defmodule PubkyRoomsWeb.RoomLiveTest do
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  import Phoenix.LiveViewTest

  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Message, Paths, Room}

  setup %{conn: conn} do
    reset_state()
    {sid, alice} = Fixtures.login("alice")
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Slice", "visibility" => "public"})

    %{
      conn: conn,
      alice_conn: init_test_session(conn, sid: sid),
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
    bob_conn = init_test_session(ctx.conn, sid: bob_sid)

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

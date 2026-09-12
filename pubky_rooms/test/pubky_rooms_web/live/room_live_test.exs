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

  test "earlier messages are loaded above the window on request, in order", ctx do
    for i <- 1..12 do
      {:ok, m} =
        Message.new(
          ctx.alice,
          ctx.room |> Room.ref(),
          "msg #{String.pad_leading("#{i}", 2, "0")}"
        )

      Fake.seed(ctx.alice, Message.path(m), Message.encode(m))
    end

    Application.put_env(:pubky_rooms, :page_size, 4)
    on_exit(fn -> Application.delete_env(:pubky_rooms, :page_size) end)

    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    html = wait_for(fn -> render(view) end, &(&1 =~ "msg 12"))
    # test config: the newest 5 are shown, with the "earlier" control
    refute html =~ "msg 07"
    assert has_element?(view, "#messages-top button", "Load earlier messages")

    view |> element("#messages-top button") |> render_click()
    html = wait_for(fn -> render(view) end, &(&1 =~ "msg 04"))
    assert ordered?(html, ["msg 04", "msg 05", "msg 07", "msg 08", "msg 12"])
    refute html =~ "msg 03"

    render_hook(view, "load_older", %{})
    html = wait_for(fn -> render(view) end, &(&1 =~ "msg 01"))
    assert ordered?(html, ["msg 01", "msg 02", "msg 03", "msg 04", "msg 08", "msg 12"])
    assert html =~ ~r/id="messages-top" class="[^"]*hidden/
  end

  defp ordered?(html, needles) do
    positions = Enum.map(needles, fn n -> :binary.match(html, n) |> elem(0) end)
    positions == Enum.sort(positions)
  end

  test "own messages can be edited and deleted; others see the change", ctx do
    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    {:ok, anon, _} = live(ctx.conn, ctx.path)

    view |> form("#composer", message: %{content: "typo herre"}) |> render_submit()
    render_async(view)
    wait_for(fn -> render(view) end, &(&1 =~ "Stored on your homeserver"))
    [%Message{} = stored] = messages_on_homeserver(ctx.alice, ctx.room)
    id = "msg-#{ctx.alice}-#{stored.msg_id}"

    # edit: the composer switches to edit mode with the text, the same file is overwritten
    view |> element("##{id} button[aria-label=Edit]") |> render_click()
    assert render(view) =~ "Editing your message"
    view |> form("#composer", message: %{content: "typo fixed"}) |> render_submit()
    render_async(view)
    html = wait_for(fn -> render(view) end, &(&1 =~ "typo fixed"))
    assert html =~ "(edited)"
    refute html =~ "typo herre"
    refute html =~ "Editing your message"

    stored_id = stored.msg_id

    assert [%Message{msg_id: ^stored_id, content: "typo fixed", edited_at: edited}] =
             messages_on_homeserver(ctx.alice, ctx.room)

    assert is_integer(edited)
    assert wait_for(fn -> render(anon) end, &(&1 =~ "typo fixed"))

    # cancelling an edit puts the composer back
    view |> element("##{id} button[aria-label=Edit]") |> render_click()
    view |> element("#composer-context button[aria-label=Cancel]") |> render_click()
    refute render(view) =~ "Editing your message"

    # delete: gone locally at once, gone on the homeserver, gone for others
    view |> element("##{id} button[aria-label=Delete]") |> render_click()
    refute render(view) =~ "typo fixed"
    render_async(view)
    assert wait_for(fn -> messages_on_homeserver(ctx.alice, ctx.room) end, &(&1 == []))
    assert wait_for(fn -> render(anon) end, &(not (&1 =~ "typo fixed")))
  end

  test "a failed edit restores the stored message", ctx do
    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    view |> form("#composer", message: %{content: "keep me"}) |> render_submit()
    render_async(view)
    wait_for(fn -> render(view) end, &(&1 =~ "Stored on your homeserver"))
    [stored] = messages_on_homeserver(ctx.alice, ctx.room)
    id = "msg-#{ctx.alice}-#{stored.msg_id}"

    view |> element("##{id} button[aria-label=Edit]") |> render_click()
    Fake.fail_next(Message.path(stored), :quota)
    view |> form("#composer", message: %{content: "lost edit"}) |> render_submit()
    render_async(view)
    html = wait_for(fn -> render(view) end, &(&1 =~ "Edit not stored"))
    assert html =~ "keep me"
    refute html =~ "lost edit"
    assert [%Message{content: "keep me"}] = messages_on_homeserver(ctx.alice, ctx.room)
  end

  test "replies quote the original and are stored with reply_to", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    alice_view |> form("#composer", message: %{content: "original question?"}) |> render_submit()
    render_async(alice_view)
    [original] = messages_on_homeserver(ctx.alice, ctx.room)
    id = "msg-#{ctx.alice}-#{original.msg_id}"

    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    wait_for(fn -> render(bob_view) end, &(&1 =~ "original question?"))
    # bob cannot edit or delete alice's message
    refute has_element?(bob_view, "##{id} button[aria-label=Edit]")
    refute has_element?(bob_view, "##{id} button[aria-label=Delete]")

    bob_view |> element("##{id} button[aria-label=Reply]") |> render_click()
    assert render(bob_view) =~ "Replying to"
    bob_view |> form("#composer", message: %{content: "the answer"}) |> render_submit()
    render_async(bob_view)

    html = wait_for(fn -> render(alice_view) end, &(&1 =~ "the answer"))
    # the quote links to the original and shows its text
    assert html =~ ~s(href="##{id}")
    assert html =~ ~r/the answer/
    assert [%Message{reply_to: reply_to}] = messages_on_homeserver(bob, ctx.room)
    assert reply_to == original.uri

    # an anonymous visitor has no actions at all
    {:ok, anon, _} = live(ctx.conn, ctx.path)
    wait_for(fn -> render(anon) end, &(&1 =~ "the answer"))
    refute has_element?(anon, "button[aria-label=Reply]")
  end

  test "members react from the palette and toggle their reaction; others see counts", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    alice_view |> form("#composer", message: %{content: "react here"}) |> render_submit()
    render_async(alice_view)
    [stored] = messages_on_homeserver(ctx.alice, ctx.room)
    id = "msg-#{ctx.alice}-#{stored.msg_id}"

    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    wait_for(fn -> render(bob_view) end, &(&1 =~ "react here"))
    assert has_element?(bob_view, "##{id}-palette button[aria-label='React with fire']")

    render_click(bob_view, "react", %{"id" => id, "key" => "fire"})
    render_async(bob_view)
    html = wait_for(fn -> render(bob_view) end, &(&1 =~ ~s(title="fire · 1")))

    assert html =~
             ~r/aria-pressed="true"[^>]*title="fire · 1"|title="fire · 1"[^>]*aria-pressed="true"/

    assert Map.has_key?(
             Fake.files(bob),
             Paths.reaction(Room.ref(ctx.room), ctx.alice, stored.msg_id, "fire")
           )

    # alice sees the count, not pressed
    html = wait_for(fn -> render(alice_view) end, &(&1 =~ ~s(title="fire · 1")))

    assert html =~
             ~r/aria-pressed="false"[^>]*title="fire · 1"|title="fire · 1"[^>]*aria-pressed="false"/

    # clicking the chip toggles it off again
    render_click(bob_view, "react", %{"id" => id, "key" => "fire"})
    render_async(bob_view)
    wait_for(fn -> render(alice_view) end, &(not (&1 =~ "fire · 1")))

    refute Map.has_key?(
             Fake.files(bob),
             Paths.reaction(Room.ref(ctx.room), ctx.alice, stored.msg_id, "fire")
           )

    # anonymous viewers see chips but cannot react
    render_click(bob_view, "react", %{"id" => id, "key" => "up"})
    render_async(bob_view)
    {:ok, anon, _} = live(ctx.conn, ctx.path)
    html = wait_for(fn -> render(anon) end, &(&1 =~ ~s(title="up · 1")))
    assert html =~ ~r/<button[^>]*disabled[^>]*title="up · 1"|title="up · 1"[^>]*disabled/
    refute has_element?(anon, "##{id}-palette")
  end

  test "the creator removes and restores a member; the member sees why", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    bob_view |> form("#composer", message: %{content: "bob speaks"}) |> render_submit()
    render_async(bob_view)

    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(alice_view) end, &(&1 =~ "bob speaks"))
    # bob has no moderation controls
    refute has_element?(bob_view, "#member-#{ctx.alice} button[aria-label='Remove from room']")

    alice_view
    |> element("#member-#{bob} button[aria-label='Remove from room']")
    |> render_click()

    assert has_element?(alice_view, "#ban-dialog")
    alice_view |> form("#ban-form", ban: %{reason: "spam"}) |> render_submit()
    render_async(alice_view)

    html = wait_for(fn -> render(alice_view) end, &(&1 =~ "Removed by you"))
    refute html =~ "bob speaks"
    assert html =~ ~s(id="banned-#{bob}")
    refute has_element?(alice_view, "#member-#{bob}")

    html = wait_for(fn -> render(bob_view) end, &(&1 =~ "removed from this room"))
    assert html =~ "spam"
    refute has_element?(bob_view, "#composer")
    assert Map.has_key?(Fake.files(ctx.alice), Paths.ban(ctx.room.id, bob))

    alice_view |> element("#banned-#{bob} button", "Restore") |> render_click()
    render_async(alice_view)
    wait_for(fn -> render(bob_view) end, &has_composer?/1)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "bob speaks"))
  end

  test "muting hides an author's messages in this tab only", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    bob_view |> form("#composer", message: %{content: "first from bob"}) |> render_submit()
    render_async(bob_view)

    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    {:ok, other_tab, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(alice_view) end, &(&1 =~ "first from bob"))

    alice_view |> element("#member-#{bob} button[aria-label='Mute for me']") |> render_click()
    refute render(alice_view) =~ "first from bob"
    assert has_element?(alice_view, "#member-#{bob} button[aria-label=Unmute]")

    bob_view |> form("#composer", message: %{content: "second from bob"}) |> render_submit()
    render_async(bob_view)
    assert wait_for(fn -> render(other_tab) end, &(&1 =~ "second from bob"))
    refute render(alice_view) =~ "second from bob"

    alice_view |> element("#member-#{bob} button[aria-label=Unmute]") |> render_click()
    html = render(alice_view)
    assert html =~ "first from bob"
    assert html =~ "second from bob"
    # nothing was written anywhere for a mute
    refute Fake.files(ctx.alice) |> Map.keys() |> Enum.any?(&String.contains?(&1, "mute"))
  end

  test "anonymous viewers are counted, never identified", ctx do
    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "1 online"))
    refute render(alice_view) =~ "anonymous"

    {:ok, anon, _} = live(ctx.conn, ctx.path)
    html = wait_for(fn -> render(alice_view) end, &(&1 =~ "1 anonymous"))
    assert html =~ "1 online"
    # the anonymous viewer sees the same totals
    assert wait_for(fn -> render(anon) end, &(&1 =~ "1 anonymous"))

    GenServer.stop(anon.pid)
    refute wait_for(fn -> render(alice_view) end, &(not (&1 =~ "anonymous"))) =~ "anonymous"
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

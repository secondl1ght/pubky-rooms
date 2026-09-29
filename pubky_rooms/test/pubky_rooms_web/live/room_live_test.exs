defmodule PubkyRoomsWeb.RoomLiveTest do
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  import Phoenix.LiveViewTest

  alias PubkyRooms.{Fixtures, Profiles, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Directory, Message, Paths, Room, RoomServer}
  alias PubkyRooms.Tags.Tag

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

  test "the disconnected first render already shows what the directory knows", ctx do
    # a hard refresh paints the real header, members and composer state, not placeholders
    html = ctx.alice_conn |> get(ctx.path) |> html_response(200)
    assert html =~ ">Slice · Pubky Rooms</title>"
    assert html =~ ~r/<h1[^>]*>\s*Slice\s*<\/h1>/
    assert html =~ "Members · 1"
    assert html =~ ~s(href="#{ctx.path}/settings")
    refute html =~ "Join room"
    refute html =~ "room-loading"
    # the room is cold (no server yet): only the messages wait
    assert html =~ "Loading messages…"

    # an anonymous visitor: the sign-in prompt, no composer, no Join, no gear
    html = ctx.conn |> get(ctx.path) |> html_response(200)
    assert html =~ "Sign in to chat."
    refute html =~ ~s(id="composer")
    refute html =~ "Join room"
    refute html =~ "/settings\""
    assert html =~ "Members · 1"

    {bob_sid, bob} = Fixtures.login("bob")
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))
    html = bob_conn |> get(ctx.path) |> html_response(200)
    assert html =~ "Join room"
    refute html =~ "/settings\""

    # a member who is not the creator: composer, no Join, no gear
    :ok = Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    html = bob_conn |> get(ctx.path) |> html_response(200)
    assert html =~ ~s(id="composer")
    refute html =~ "Join room"
    refute html =~ "/settings\""
    assert html =~ "Members · 2"

    # a warm room (its server is running, as after any refresh) paints everything:
    # messages and the tag "+" included; nothing is left for the socket to fill in
    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    view |> form("#composer", message: %{content: "first paint"}) |> render_submit()
    render_async(view)
    # the fake homeserver's event reaches the room server a moment after the reply
    html =
      wait_for(
        fn -> ctx.alice_conn |> get(ctx.path) |> html_response(200) end,
        &(&1 =~ "first paint")
      )

    assert html =~ "first paint"
    assert html =~ ~s(id="room-tag-input")
    refute html =~ "Loading messages"

    # mutes come from their (warm) cache too: a muted author is absent from the first paint
    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    bob_view |> form("#composer", message: %{content: "from bob"}) |> render_submit()
    render_async(bob_view)
    wait_for(fn -> render(view) end, &(&1 =~ "from bob"))
    view |> element("#member-#{bob} button[aria-label='Mute for me']") |> render_click()
    render_async(view)
    refute render(view) =~ "from bob"
    html = ctx.alice_conn |> get(ctx.path) |> html_response(200)
    refute html =~ "from bob"
    assert html =~ "lucide-volume-x"
    assert html =~ ~s(aria-label="Unmute")

    # a cold mute cache (server restart, an hour away) is loaded before the first paint
    PubkyRooms.Mutes.reset()
    assert PubkyRooms.Mutes.cached(ctx.alice) == nil
    html = ctx.alice_conn |> get(ctx.path) |> html_response(200)
    assert html =~ "first paint"
    refute html =~ "from bob"
    assert html =~ "lucide-volume-x"

    # the lists cannot be loaded in time: the first paint keeps the header,
    # members and composer but leaves every message to the socket, so nothing
    # muted can show and then vanish (anonymous visitors are unaffected)
    PubkyRooms.Mutes.reset()
    :sys.suspend(PubkyRooms.Mutes)

    try do
      html = ctx.alice_conn |> get(ctx.path) |> html_response(200)
      assert html =~ "Members · 2"
      assert html =~ ~s(id="composer")
      assert html =~ "Loading messages…"
      refute html =~ "first paint"
      refute html =~ "from bob"
      # no mute marker or mute/unmute action can be shown wrong: none is shown
      refute html =~ "lucide-volume-x"
      refute html =~ "Mute for me"
      refute html =~ ~s(aria-label="Unmute")
      assert html =~ ~s(aria-label="Remove from room")

      html = ctx.conn |> get(ctx.path) |> html_response(200)
      assert html =~ "first paint"
      assert html =~ "from bob"
    after
      :sys.resume(PubkyRooms.Mutes)
    end

    # and the connected render after such a first paint is the usual one
    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    html = wait_for(fn -> render(view) end, &(&1 =~ "first paint"))
    refute html =~ "from bob"

    # a cold archive: closed badge and notice from the definition, no gear
    {sid, _} = Fixtures.login("alice")

    {:ok, archive} =
      Rooms.create_room(sid, ctx.alice, %{"name" => "Old", "visibility" => "public"})

    :ok = Rooms.close_room(sid, ctx.alice, archive)
    html = ctx.alice_conn |> get(~p"/r/#{ctx.alice}/#{archive.id}") |> html_response(200)
    assert html =~ ~s(id="closed-badge")
    assert html =~ ~s(id="closed-notice")
    refute html =~ "/settings\""

    # a room this node has never seen: one loading state for the whole page
    html = ctx.conn |> get(~p"/r/#{ctx.alice}/0035R2S3QP3RY") |> html_response(200)
    assert html =~ ~s(id="room-loading")
    refute html =~ "Members ·"
  end

  test "the creator sends a message that is confirmed by the homeserver event", ctx do
    {:ok, view, _html} = live(ctx.alice_conn, ctx.path)
    html = render(view)
    assert html =~ "No messages yet"
    # the invitation lives in the composer only, not repeated under the placeholder
    refute html =~ "Say hello."
    assert has_element?(view, "#composer-input[placeholder='Say hello…']")
    # a click anywhere in the dashed box focuses the input (a client-only command)
    assert has_element?(view, ~s(#composer-box[phx-click*="focus"][phx-click*="composer-input"]))
    # the storage path is a tooltip on the info mark, not a permanent line
    assert has_element?(view, ~s(#composer-storage-tip[data-tip^="Stored at pubky://"]))
    refute html =~ "<code"

    view |> form("#composer", message: %{content: "hello sovereign world"}) |> render_submit()

    # the fake homeserver confirms synchronously inside the async publish
    render_async(view)
    html = wait_for(fn -> render(view) end, &(&1 =~ "Stored on your homeserver"))
    assert html =~ "hello sovereign world"
    refute html =~ "Sending to your homeserver"
    # the delivery tooltip opens downwards (a top row's upward tooltip is clipped)
    assert html =~ ~s(class="tooltip tooltip-bottom)
    # pre-wrap text hugs its tags: no template newline rendered as a blank line
    assert html =~ ~r/<p[^>]*whitespace-pre-wrap[^>]*>hello sovereign world<\/p>/

    assert [%Message{content: "hello sovereign world"}] =
             messages_on_homeserver(ctx.alice, ctx.room)

    # blank messages are rejected before any write; the error is small and
    # disappears as soon as the member types again
    view |> form("#composer", message: %{content: "   "}) |> render_submit()
    html = render(view)
    assert html =~ "Write a message first."
    assert html =~ "text-destructive text-xs"
    view |> form("#composer", message: %{content: "h"}) |> render_change()
    refute render(view) =~ "Write a message first."
    # a change with nothing to clear leaves the form alone
    view |> form("#composer", message: %{content: "he"}) |> render_change()
    refute render(view) =~ "Write a message first."
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
    assert html =~ "Sign in to chat"
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

    # before joining, the creator's message shows no reply/react actions
    creator_view |> form("#composer", message: %{content: "welcome"}) |> render_submit()
    render_async(creator_view)
    wait_for(fn -> render(bob_view) end, &(&1 =~ "welcome"))
    refute has_element?(bob_view, "button[aria-label=Reply]")

    bob_view |> element("button", "Join room") |> render_click()
    render_async(bob_view)
    assert wait_for(fn -> render(bob_view) end, &has_composer?/1)
    assert Map.has_key?(Fake.files(bob), Paths.member(Room.ref(ctx.room)))
    # …and the existing rows gain them without a reload
    assert has_element?(bob_view, "button[aria-label=Reply]")

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

    # the actions pill (hover from sm, behind a "More actions" toggle below)
    # exists for the author and not for a visitor who can do nothing
    assert has_element?(view, "##{id}-actions")

    assert has_element?(
             view,
             "##{id} button[aria-label='More actions'][aria-controls='#{id}-actions']"
           )

    refute has_element?(anon, "##{id}-actions")
    refute has_element?(anon, "##{id} button[aria-label='More actions']")
    # the reaction palette lives in the actions box, so it opens where the click was
    assert has_element?(view, "##{id}-menu ##{id}-palette[role=group]")
    # the reaction palette is a flex row: JS.toggle must reveal it as flex, not block
    assert has_element?(view, ~s(##{id} button[aria-label=React][phx-click*='"display":"flex"']))
    # toggle and pill share a wrapper whose click-away closes the pill on phones
    assert has_element?(view, "##{id}-menu[phx-click-away*='#{id}-actions']")

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
    # the quote shows the original's text and jumps to it
    [reply] = messages_on_homeserver(bob, ctx.room)
    reply_id = "msg-#{bob}-#{reply.msg_id}"
    assert has_element?(alice_view, "##{reply_id} button[phx-click=jump][phx-value-id=#{id}]")
    assert html =~ "original question?"
    alice_view |> element("##{reply_id} button[phx-click=jump]") |> render_click()
    assert_push_event(alice_view, "scroll_to", %{id: ^id})
    assert [%Message{reply_to: reply_to}] = messages_on_homeserver(bob, ctx.room)
    assert reply_to == original.uri

    # an anonymous visitor has no actions at all
    {:ok, anon, _} = live(ctx.conn, ctx.path)
    wait_for(fn -> render(anon) end, &(&1 =~ "the answer"))
    refute has_element?(anon, "button[aria-label=Reply]")

    # the quote follows the original: an edit changes its text for everyone…
    alice_view |> element("##{id} button[aria-label=Edit]") |> render_click()
    alice_view |> form("#composer", message: %{content: "edited question?"}) |> render_submit()
    render_async(alice_view)

    for view <- [alice_view, bob_view, anon] do
      html =
        wait_for(
          fn -> render(view) end,
          &(&1 =~ ~r/phx-value-id="#{id}"[^>]*>.*?edited question\?/s)
        )

      refute html =~
               ~r/phx-value-id="#{id}"[^>]*>[^<]*<span[^>]*>[^<]*<\/span><span[^>]*>original question\?/
    end

    # …and a delete turns it into the missing state, no stale text left behind
    alice_view |> element("##{id} button[aria-label=Delete]") |> render_click()
    render_async(alice_view)

    for view <- [alice_view, bob_view, anon] do
      html = wait_for(fn -> render(view) end, &(&1 =~ "Replying to an earlier message"))
      refute html =~ "edited question?"
      refute has_element?(view, "##{reply_id} button[title='Show the original message']")
    end
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

    # every write is off for the banned member: reactions, replies, tags, typing
    refute has_element?(bob_view, "button[aria-label=React]")
    refute has_element?(bob_view, "button[aria-label=Reply]")
    refute has_element?(bob_view, "#room-tag-input")
    assert html =~ ~r/<button[^>]*disabled[^>]*phx-value-label="room"/
    render_click(bob_view, "react", %{"id" => "msg-#{ctx.alice}-0000000000000", "key" => "up"})
    render_hook(bob_view, "add_tag", %{"label" => "sneaky"})
    render_hook(bob_view, "toggle_tag", %{"label" => "room"})
    render_hook(bob_view, "typing", %{})
    render_async(bob_view)
    refute Fake.files(bob) |> Map.keys() |> Enum.any?(&String.contains?(&1, "/tags/"))
    refute Fake.files(bob) |> Map.keys() |> Enum.any?(&String.contains?(&1, "/reactions/"))
    refute render(alice_view) =~ "is typing"

    alice_view |> element("#banned-#{bob} button", "Restore") |> render_click()
    render_async(alice_view)
    wait_for(fn -> render(bob_view) end, &has_composer?/1)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "bob speaks"))
  end

  test "muting hides an author's messages everywhere the viewer is signed in and is saved on their homeserver",
       ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    bob_view |> form("#composer", message: %{content: "first from bob"}) |> render_submit()
    render_async(bob_view)

    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    {:ok, other_tab, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(alice_view) end, &(&1 =~ "first from bob"))
    wait_for(fn -> render(other_tab) end, &(&1 =~ "first from bob"))

    alice_view |> element("#member-#{bob} button[aria-label='Mute for me']") |> render_click()
    refute render(alice_view) =~ "first from bob"
    assert has_element?(alice_view, "#member-#{bob} button[aria-label=Unmute]")

    # the marker lands on alice's homeserver and her other tab follows
    render_async(alice_view)
    assert wait_for(fn -> Fake.files(ctx.alice) end, &Map.has_key?(&1, Paths.mute(bob)))
    assert wait_for(fn -> render(other_tab) end, &(not (&1 =~ "first from bob")))

    bob_view |> form("#composer", message: %{content: "second from bob"}) |> render_submit()
    render_async(bob_view)
    assert wait_for(fn -> render(bob_view) end, &(&1 =~ "second from bob"))
    refute render(alice_view) =~ "second from bob"
    refute render(other_tab) =~ "second from bob"

    # a fresh visit reads the list from the homeserver before showing history
    {:ok, fresh, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(fresh) end, &(&1 =~ "member-#{bob}"))
    refute render(fresh) =~ "first from bob"
    assert render(fresh) =~ "Muted for you"

    alice_view |> element("#member-#{bob} button[aria-label=Unmute]") |> render_click()
    render_async(alice_view)
    html = wait_for(fn -> render(alice_view) end, &(&1 =~ "second from bob"))
    assert html =~ "first from bob"
    assert wait_for(fn -> Fake.files(ctx.alice) end, &(not Map.has_key?(&1, Paths.mute(bob))))
    assert wait_for(fn -> render(other_tab) end, &(&1 =~ "second from bob"))
  end

  test "a quote of a message outside the loaded window loads earlier pages and then jumps to it",
       ctx do
    %{alice: alice, room: room} = ctx
    ref = Room.ref(room)
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, ref)

    # the original is the oldest of 13 messages: beyond the first listing page
    # (bootstrap_per_member 10) and far outside the bootstrap window (5)
    {:ok, needle} = Message.new(alice, ref, "the needle")
    Fake.seed(alice, Message.path(needle), Message.encode(needle))

    for i <- 1..12 do
      {:ok, m} = Message.new(alice, ref, "filler #{i}")
      Fake.seed(alice, Message.path(m), Message.encode(m))
    end

    {:ok, reply} = Message.new(bob, ref, "found it?", reply_to: needle.uri)
    Fake.seed(bob, Message.path(reply), Message.encode(reply))
    needle_id = "msg-#{alice}-#{needle.msg_id}"
    reply_id = "msg-#{bob}-#{reply.msg_id}"

    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(view) end, &(&1 =~ "found it?"))
    refute has_element?(view, "##{needle_id}")
    assert has_element?(view, "##{reply_id} button[phx-click=jump]", "earlier message")

    # the jump pages until the original is in the window, then scrolls to it
    view |> element("##{reply_id} button[phx-click=jump]") |> render_click()
    wait_for(fn -> render_async(view) end, &(&1 =~ "the needle"))
    assert_push_event(view, "scroll_to", %{id: ^needle_id}, 2_000)
    assert has_element?(view, "##{needle_id}")

    # now in the window: the same click scrolls right away, no loading
    view |> element("##{reply_id} button[phx-click=jump]") |> render_click()
    assert_push_event(view, "scroll_to", %{id: ^needle_id})
    refute render(view) =~ "Loading earlier messages"

    # a quote of a message nobody holds gives up once the history is exhausted
    render_click(view, "jump", %{"id" => "msg-#{alice}-0000000000001"})
    assert wait_for(fn -> render_async(view) end, &(&1 =~ "no longer available"))
  end

  test "below xl the members list opens as a sheet with the same actions", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    {:ok, bob_view, _} = live(init_test_session(ctx.conn, Fixtures.cookie(bob_sid)), ctx.path)
    bob_view |> form("#composer", message: %{content: "sheet me"}) |> render_submit()
    render_async(bob_view)

    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(view) end, &(&1 =~ "sheet me"))
    assert has_element?(view, "#members-button", "2")
    refute has_element?(view, "#members-sheet")

    view |> element("#members-button") |> render_click()
    assert has_element?(view, "#members-sheet")
    assert has_element?(view, "#members-sheet h2#sheet-members-title", "Members · 2")
    # the same panel as the xl sidebar card: users icon, live online line, rows
    assert has_element?(view, "#sheet-members-title span.lucide-users")
    assert has_element?(view, "#members-sheet #sheet-members-description", "2 online")
    assert has_element?(view, "#members-sheet [aria-labelledby=sheet-members-title]")
    assert has_element?(view, "#sheet-member-#{bob}")
    # the sidebar rows keep their ids; nothing is duplicated
    assert has_element?(view, "#member-#{bob}")

    view |> element("#sheet-member-#{bob} button[aria-label='Mute for me']") |> render_click()
    refute render(view) =~ "sheet me"
    assert has_element?(view, "#sheet-member-#{bob} button[aria-label=Unmute]")
    assert has_element?(view, "#member-#{bob} button[aria-label=Unmute]")

    # the creator can remove from the sheet too
    assert has_element?(view, "#sheet-member-#{bob} button[aria-label='Remove from room']")

    render_click(view, "close_members")
    refute has_element?(view, "#members-sheet")

    # anonymous readers can open it as well (members are public); no actions
    {:ok, anon, _} = live(ctx.conn, ctx.path)
    wait_for(fn -> render(anon) end, &(&1 =~ "sheet me"))
    anon |> element("#members-button") |> render_click()
    assert has_element?(anon, "#sheet-member-#{bob}")
    refute has_element?(anon, "#sheet-member-#{bob} button")
  end

  test "mutes made in Pubky App are honored read-only", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))
    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    bob_view |> form("#composer", message: %{content: "bob from the app"}) |> render_submit()
    render_async(bob_view)

    Fake.seed(ctx.alice, PubkyRooms.Mutes.app_mutes_dir() <> bob, ~s({"created_at":1}))

    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(alice_view) end, &(&1 =~ "member-#{bob}"))
    html = render(alice_view)
    refute html =~ "bob from the app"
    assert html =~ "Muted in Pubky App"
    refute has_element?(alice_view, "#member-#{bob} button[aria-label=Unmute]")
    refute has_element?(alice_view, "#member-#{bob} button[aria-label='Mute for me']")

    # nothing is written for a Pubky App mute; unmute is refused politely
    render_click(alice_view, "unmute", %{"z32" => bob})
    assert render(alice_view) =~ "unmute them there"

    refute Fake.files(ctx.alice)
           |> Map.keys()
           |> Enum.any?(&String.starts_with?(&1, Paths.mutes_dir()))

    refute render(alice_view) =~ "bob from the app"
  end

  test "the creator renames the room and can close it; others follow live", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    Rooms.join(bob_sid, bob, Room.ref(ctx.room))
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))

    # non-creators are sent back from /settings
    {:ok, bob_view, _} = live(bob_conn, ctx.path <> "/settings")
    refute has_element?(bob_view, "#room-settings-form")
    refute has_element?(bob_view, "a[aria-label='Room settings']")

    {:ok, view, _} = live(ctx.alice_conn, ctx.path)
    view |> element("a[aria-label='Room settings']") |> render_click()
    assert_patch(view, ctx.path <> "/settings")
    assert has_element?(view, "#room-settings-form")
    # same panel width as the Open-a-room dialog
    [panel_tag] = Regex.run(~r/<div[^>]*id="room-settings-container"[^>]*>/, render(view))
    assert panel_tag =~ "sm:w-[34rem]"
    refute panel_tag =~ "sm:w-auto"
    assert has_element?(view, "#room-tag-input")

    view
    |> form("#room-settings-form", room: %{name: "", topic: "x", visibility: "public"})
    |> render_submit()

    assert render(view) =~ "Give the room a name of 1 to 64 characters."

    view
    |> form("#room-settings-form",
      room: %{name: "Renamed", topic: "New topic", visibility: "unlisted"}
    )
    |> render_submit()

    render_async(view)
    assert_patch(view, ctx.path)
    html = wait_for(fn -> render(view) end, &(&1 =~ "Renamed"))
    assert html =~ "New topic"
    # the label shows at every width (no hidden/sm: classes)
    assert html =~ ~s(id="unlisted-label" class="inline-flex)

    assert {:ok, %Room{name: "Renamed", visibility: "unlisted"}} =
             Directory.fetch_room(Room.ref(ctx.room))

    # an unlisted room takes no new tags: the input is gone for everyone,
    # the creator's own "room" tag was deleted, so the row disappears
    refute has_element?(view, "#room-tag-input")
    assert wait_for(fn -> render(bob_view) end, &(&1 =~ "Renamed"))
    refute has_element?(bob_view, "#room-tag-input")
    refute has_element?(bob_view, "#room-tags")

    # relisting writes "room" again and tagging comes back for everyone signed in
    view |> element("a[aria-label='Room settings']") |> render_click()

    view
    |> form("#room-settings-form",
      room: %{name: "Renamed", topic: "New topic", visibility: "public"}
    )
    |> render_submit()

    render_async(view)
    assert_patch(view, ctx.path)
    assert wait_for(fn -> render(view) end, &(&1 =~ ~s(id="room-tag-input")))
    refute has_element?(view, "#unlisted-label")
    assert Directory.own_tags(Room.ref(ctx.room), ctx.alice) == ["room"]
    assert wait_for(fn -> render(bob_view) end, &(&1 =~ ~s(id="room-tag-input")))
    assert has_element?(bob_view, "#room-tags button[phx-value-label='room']")

    # bob has a message of his own he could edit before the room closes
    bob_view |> form("#composer", message: %{content: "bob before close"}) |> render_submit()
    render_async(bob_view)
    [bobs] = messages_on_homeserver(bob, ctx.room)
    bob_id = "msg-#{bob}-#{bobs.msg_id}"
    wait_for(fn -> render(bob_view) end, &(&1 =~ "bob before close"))
    assert has_element?(bob_view, "##{bob_id} button[aria-label=Edit]")

    # closing deletes the definition; viewers learn the room is closed
    view |> element("a[aria-label='Room settings']") |> render_click()
    view |> element("#room-settings button", "Close room") |> render_click()
    assert_redirect(view, "/", 2_000)
    refute Map.has_key?(Fake.files(ctx.alice), Paths.room(ctx.room.id))
    html = wait_for(fn -> render(bob_view) end, &(&1 =~ "read-only now"))
    assert %Room{closed_at: closed_at} = Directory.get(Room.ref(ctx.room))
    assert is_integer(closed_at)
    assert has_element?(bob_view, "#closed-badge")

    # …and the room is read-only for everyone: no composer, no row actions, no tags
    assert html =~ "bob before close"
    refute has_element?(bob_view, "#composer")
    refute has_element?(bob_view, "##{bob_id} button[aria-label=Edit]")
    refute has_element?(bob_view, "##{bob_id} button[aria-label=Delete]")
    refute has_element?(bob_view, "button[aria-label=React]")
    refute has_element?(bob_view, "#room-tag-input")
    render_click(bob_view, "delete", %{"id" => bob_id})
    render_hook(bob_view, "add_tag", %{"label" => "late"})
    render_async(bob_view)
    assert [%Message{content: "bob before close"}] = messages_on_homeserver(bob, ctx.room)
    refute Fake.files(bob) |> Map.keys() |> Enum.any?(&String.contains?(&1, "/tags/"))

    # the archive survives a fresh visit: history from the members' folders,
    # read-only for a member and for an anonymous reader alike
    RoomServer.whereis(Room.ref(ctx.room)) |> GenServer.stop()
    {:ok, again, _} = live(bob_conn, ctx.path)
    html = wait_for(fn -> render(again) end, &(&1 =~ "bob before close"))
    assert html =~ "Renamed"
    assert html =~ "read-only now"
    assert has_element?(again, "#closed-badge")
    refute has_element?(again, "#composer")
    refute has_element?(again, "##{bob_id} button[aria-label=Edit]")
    # leaving stays possible: the marker is bob's own file and drops the archive from his lobby
    assert has_element?(again, "button", "Leave")

    # the creator has no settings on an archive (saving would recreate the definition)
    {:ok, creator_again, _} = live(ctx.alice_conn, ctx.path)
    wait_for(fn -> render(creator_again) end, &(&1 =~ "bob before close"))
    refute has_element?(creator_again, "a[aria-label='Room settings']")
    {:ok, redirected, _} = live(ctx.alice_conn, ctx.path <> "/settings")
    wait_for(fn -> render(redirected) end, &(&1 =~ "bob before close"))
    refute has_element?(redirected, "#room-settings-form")

    {:ok, anon, _} = live(ctx.conn, ctx.path)
    html = wait_for(fn -> render(anon) end, &(&1 =~ "bob before close"))
    assert html =~ "read-only now"
    refute html =~ "Join room"
  end

  test "room tags are shown to everyone; signed-in users toggle their own", ctx do
    {bob_sid, bob} = Fixtures.login("bob")
    bob_conn = init_test_session(ctx.conn, Fixtures.cookie(bob_sid))
    uri = Room.uri(ctx.room)

    {:ok, anon, html} = live(ctx.conn, ctx.path)
    assert html =~ ~s(id="room-tags")

    assert html =~
             ~r/aria-pressed="false"[^>]*phx-value-label="room"|phx-value-label="room"[^>]*aria-pressed="false"/

    assert html =~ ~r/<button[^>]*disabled[^>]*phx-value-label="room"/
    refute has_element?(anon, "#room-tag-input")

    # the creator's own "room" chip is fixed: disabled, explained, and the
    # server keeps the file even if the event is forced
    {:ok, alice_view, alice_html} = live(ctx.alice_conn, ctx.path)
    assert alice_html =~ ~r/<button[^>]*disabled[^>]*phx-value-label="room"/
    assert alice_html =~ ~s(title="Added automatically")
    render_click(alice_view, "toggle_tag", %{"label" => "room"})
    render_async(alice_view)
    assert Map.has_key?(Fake.files(ctx.alice), Tag.path(uri, "room"))
    assert render(alice_view) =~ "Listed rooms keep their room tag."

    # bob (not even a member) adds a tag and joins alice on "room"
    {:ok, bob_view, _} = live(bob_conn, ctx.path)
    assert has_element?(bob_view, "#room-tag-input")
    render_hook(bob_view, "add_tag", %{"label" => " Lightning "})
    render_async(bob_view)
    html = wait_for(fn -> render(bob_view) end, &(&1 =~ "lightning"))
    assert html =~ ~r/aria-pressed="true"[^>]*phx-value-label="lightning"/
    assert Map.has_key?(Fake.files(bob), Tag.path(uri, "lightning"))

    render_click(bob_view, "toggle_tag", %{"label" => "room"})
    render_async(bob_view)

    html =
      wait_for(
        fn -> render(bob_view) end,
        &(&1 =~ ~r/phx-value-label="room"[^>]*>[^<]*<span[^>]*>room<\/span><span[^>]*>2</)
      )

    assert html =~ ~r/aria-pressed="true"[^>]*phx-value-label="room"/

    # everyone sees the counts live
    assert wait_for(fn -> render(anon) end, &(&1 =~ "lightning"))

    # toggling again removes bob's tag file
    render_click(bob_view, "toggle_tag", %{"label" => "lightning"})
    render_async(bob_view)
    wait_for(fn -> render(bob_view) end, &(not (&1 =~ "lightning")))
    refute Map.has_key?(Fake.files(bob), Tag.path(uri, "lightning"))

    # bad labels are rejected before any write; suggestions skip the room's own tags
    render_hook(bob_view, "add_tag", %{"label" => String.duplicate("x", 21)})
    assert render(bob_view) =~ "Tags can be up to 20 characters."
    render_hook(bob_view, "tag_query", %{"q" => "roo"})
    refute has_element?(bob_view, "#room-tag-input [data-role=suggestion]")
  end

  test "anonymous viewers are counted, never identified", ctx do
    {:ok, alice_view, _} = live(ctx.alice_conn, ctx.path)
    assert wait_for(fn -> render(alice_view) end, &(&1 =~ "1 online"))
    refute render(alice_view) =~ "anonymous"

    {:ok, anon, _} = live(ctx.conn, ctx.path)
    html = wait_for(fn -> render(alice_view) end, &(&1 =~ "1 anonymous viewer"))
    assert html =~ "1 online"
    # counted under "Also here" (not a member), never in the members heading
    assert has_element?(alice_view, "#also-here", "1 anonymous viewer")
    refute has_element?(alice_view, "#members-description", "anonymous")
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

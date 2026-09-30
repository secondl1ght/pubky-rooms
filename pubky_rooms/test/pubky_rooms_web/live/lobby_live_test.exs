defmodule PubkyRoomsWeb.LobbyLiveTest do
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  import Phoenix.LiveViewTest

  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Directory, Paths, Room}

  setup do
    reset_state()
  end

  test "anonymous visitors get the pitch and a sign-in link", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Sign in with Pubky Ring"
    refute has_element?(view, "#new-room")
    # the first nav item is the lobby itself, never "your rooms" (a visitor has none)
    assert has_element?(view, "a[href='/']", "Lobby")
    assert page_title(view) =~ "Lobby"
    # one explainer, not two: "How it works" stays, the sidebar "About" is gone
    assert has_element?(view, "h2", "How it works")
    refute has_element?(view, "h2", "About")
    refute html =~ "Your rooms"

    # sign-in is the last item of the mobile tab bar (a pill like the desktop one), not a header icon
    assert has_element?(view, "nav a[href='/login']", "Sign in")
    refute has_element?(view, "header a[aria-label='Sign in']")
    # the explainer is rendered twice: the xl right column and the foot of the page below xl
    assert length(Regex.scan(~r/How it works/, render(view))) == 2
  end

  test "signed-in users get their avatar in the header and the mobile tab bar", %{conn: conn} do
    {sid, _alice} = Fixtures.login("alice")
    {:ok, view, _html} = live(init_test_session(conn, Fixtures.cookie(sid)), ~p"/")
    assert has_element?(view, "header a[href='/me']")
    assert has_element?(view, "nav a[href='/me']")
    refute has_element?(view, "a[href='/login']")
    # the explainer is for visitors; signed-in people know how it works
    refute has_element?(view, "h2", "How it works")
  end

  test "signed-in users are sent home from the sign-in page", %{conn: conn} do
    {sid, _} = Fixtures.login("already")
    conn = init_test_session(conn, Fixtures.cookie(sid))
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/login")
  end

  test "the lobby shows how many signed-in people are online", %{conn: conn} do
    {sid, _} = Fixtures.login("online")
    conn = init_test_session(conn, Fixtures.cookie(sid))
    {:ok, view, _html} = live(conn, ~p"/")
    assert wait_for(fn -> render(view) end, &(&1 =~ "1 person online"))

    {other_sid, _} = Fixtures.login("online-2")
    {:ok, _other, _} = live(init_test_session(build_conn(), Fixtures.cookie(other_sid)), ~p"/")
    assert wait_for(fn -> render(view) end, &(&1 =~ "2 people online"))
  end

  test "room cards show signed-in and anonymous viewers", %{conn: conn} do
    {sid, alice} = Fixtures.login("alice")

    {:ok, room} =
      Rooms.create_room(sid, alice, %{"name" => "Busy", "visibility" => "public"})

    alice_conn = init_test_session(conn, Fixtures.cookie(sid))
    room_path = ~p"/r/#{alice}/#{room.id}"

    {:ok, lobby, html} = live(alice_conn, ~p"/")
    assert html =~ "Busy"
    refute html =~ "Anonymous viewers"

    {:ok, _anon, _} = live(build_conn(), room_path)
    html = wait_for(fn -> render(lobby) end, &(&1 =~ "Anonymous viewers"))
    assert html =~ ~r/Anonymous viewers.*1/s
    refute html =~ "Signed-in people in the room"

    {:ok, _alice_room, _} = live(alice_conn, room_path)
    assert wait_for(fn -> render(lobby) end, &(&1 =~ "Signed-in people in the room"))
  end

  test "public rooms are listed for everyone, most recent activity first; unlisted ones are not",
       %{conn: conn} do
    {sid, alice} = Fixtures.login("alice")

    {:ok, quiet} =
      Rooms.create_room(sid, alice, %{"name" => "Quiet room", "visibility" => "public"})

    {:ok, _hidden} =
      Rooms.create_room(sid, alice, %{
        "name" => "Secret room",
        "visibility" => "unlisted"
      })

    {:ok, busy} =
      Rooms.create_room(sid, alice, %{"name" => "Busy room", "visibility" => "public"})

    Directory.touch(Room.ref(busy), System.os_time(:millisecond) + 10_000)

    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#directory h2", "Directory")
    assert html =~ "Busy room"
    assert html =~ "Quiet room"
    refute html =~ "Secret room"

    assert :binary.match(html, "Busy room") |> elem(0) <
             :binary.match(html, "Quiet room") |> elem(0)

    # activity elsewhere reorders live (debounced)
    Directory.touch(Room.ref(quiet), System.os_time(:millisecond) + 20_000)

    html =
      wait_for(
        fn -> render(view) end,
        &(:binary.match(&1, "Quiet room") |> elem(0) < :binary.match(&1, "Busy room") |> elem(0))
      )

    assert html =~ "Busy room"

    # a signed-in creator sees their own rooms only once (under "Your rooms")
    {:ok, _view, html} = live(init_test_session(conn, Fixtures.cookie(sid)), ~p"/")
    assert html =~ "Your rooms"
    assert length(Regex.scan(~r/Busy room/, html)) == 1
    # nothing left for the directory, but not "no rooms yet": they are all hers
    assert html =~ "Nothing else listed"
    refute html =~ "No rooms yet"
  end

  test "switching the new room to Unlisted drops its tags; back to Listed starts empty",
       %{conn: conn} do
    {sid, _alice} = Fixtures.login("alice")
    {:ok, view, _html} = live(init_test_session(conn, Fixtures.cookie(sid)), ~p"/rooms/new")

    render_hook(view, "add_tag", %{"label" => "bitcoin"})
    assert has_element?(view, "#new-room-tags [data-label='bitcoin']")
    assert render(view) =~ "Listed rooms are tagged"
    # the form dialog takes the wide panel (one width utility, no w-auto to beat it)
    [panel_tag] = Regex.run(~r/<div[^>]*id="new-room-container"[^>]*>/, render(view))
    assert panel_tag =~ "sm:w-[34rem]"
    refute panel_tag =~ "sm:w-auto"

    view
    |> form("#new-room-form", room: %{name: "Quiet", visibility: "unlisted"})
    |> render_change()

    refute has_element?(view, "#new-room-tags")
    refute has_element?(view, "input[name='room[tags]']")

    view
    |> form("#new-room-form", room: %{name: "Quiet", visibility: "public"})
    |> render_change()

    assert has_element?(view, "#new-room-tags")
    refute has_element?(view, "#new-room-tags [data-label='bitcoin']")
    assert has_element?(view, "#new-room-tags input[type=hidden][value='']")
  end

  test "rooms can be created with tags; the lobby lists popular tags and filters by one",
       %{conn: conn} do
    {sid, alice} = Fixtures.login("alice")
    alice_conn = init_test_session(conn, Fixtures.cookie(sid))

    {:ok, view, _html} = live(alice_conn, ~p"/rooms/new")

    # the tag input: chips are added one at a time, sanitised, deduplicated, capped
    for label <- ["Bitcoin", "dev", "bitcoin", "room", "nostr", "art", "fifth"] do
      render_hook(view, "add_tag", %{"label" => label})
    end

    assert has_element?(view, "#new-room-tags [data-label='bitcoin']")
    assert has_element?(view, "#new-room-tags input[type=hidden][value='bitcoin dev nostr art']")
    # the automatic label is shown as a fixed chip, never as a removable one
    assert has_element?(view, "#new-room-tags [data-fixed='room']")
    refute has_element?(view, "#new-room-tags [data-label='room']")
    refute has_element?(view, "#new-room-tags [data-label='fifth']")
    assert has_element?(view, "#new-room-tags button[data-role=add][disabled]")

    # the x removes a chip; suggestions come from tags this node knows
    render_hook(view, "remove_tag", %{"label" => "art"})
    refute has_element?(view, "#new-room-tags [data-label='art']")
    render_hook(view, "remove_tag", %{"label" => "nostr"})

    view
    |> form("#new-room-form", room: %{name: "Bitcoin devs", visibility: "public"})
    |> render_submit()

    {_path, _flash} = assert_redirect(view)
    %{created: [room]} = Directory.rooms_of(alice)
    assert Enum.map(Directory.tags_of(Room.ref(room)), & &1.label) == ["bitcoin", "dev", "room"]

    {:ok, _other} =
      Rooms.create_room(sid, alice, %{
        "name" => "Music",
        "visibility" => "public",
        "tags" => "music"
      })

    # a second creator gets suggestions from the tags this node already knows
    {:ok, view, _html} = live(alice_conn, ~p"/rooms/new")
    render_hook(view, "tag_query", %{"q" => "bit"})
    assert has_element?(view, "#new-room-tags [data-role=suggestion][data-label='bitcoin']")
    refute has_element?(view, "#new-room-tags [data-role=suggestion][data-label='music']")
    render_hook(view, "add_tag", %{"label" => "bitcoin"})
    render_hook(view, "tag_query", %{"q" => "bit"})
    refute has_element?(view, "#new-room-tags [data-role=suggestion]")

    # anonymous lobby: popular tags in the sidebar, chips on the cards
    {:ok, lobby, html} = live(build_conn(), ~p"/")
    assert html =~ ~s(id="popular-tags")
    assert html =~ "bitcoin"
    assert html =~ "music"
    assert html =~ "Bitcoin devs"
    assert html =~ "Music"

    # filtering by a tag
    lobby |> element("#popular-tags button", "music") |> render_click()
    assert_patch(lobby, ~p"/?tag=music")
    html = render(lobby)
    assert html =~ "Music"
    refute html =~ "Bitcoin devs"
    assert html =~ "Clear filter"

    # a card shows three tags, but the filtered one is never hidden among them
    {:ok, busy} =
      Rooms.create_room(sid, alice, %{
        "name" => "Busy tags",
        "visibility" => "public",
        "tags" => "aa bb cc dd"
      })

    {:ok, lobby2, _} = live(build_conn(), ~p"/?tag=dd")
    html = render(lobby2)
    assert html =~ "Busy tags"

    # signed in with a filter: only the filtered directory, own-room sections hidden
    {:ok, mine, html_mine} = live(alice_conn, ~p"/?tag=dd")
    refute html_mine =~ "Your rooms"
    refute html_mine =~ "Sign in with Pubky Ring"
    refute html_mine =~ "No rooms yet"
    assert length(Regex.scan(~r/Busy tags/, html_mine)) == 1
    mine |> element("a", "Clear filter") |> render_click()
    html_mine = render(mine)
    assert html_mine =~ "Your rooms"
    # every listed room is alice's own: the directory says so instead of "No rooms yet"
    assert html_mine =~ "Nothing else listed"
    refute html_mine =~ "No rooms yet"
    assert html =~ ~r/data-label="dd"|>dd</
    # the room carries aa bb cc dd room: three shown, "+2" for the rest
    assert html =~ "+2"
    refute busy.id == room.id

    lobby |> element("a", "Clear filter") |> render_click()
    assert_patch(lobby, ~p"/")
    assert render(lobby) =~ "Bitcoin devs"

    {:ok, _lobby, html} = live(build_conn(), ~p"/?tag=nothing-here")
    assert html =~ "Nothing tagged"
    assert html =~ "nothing-here"
  end

  test "closed rooms are listed under a collapsed Closed group for former members only",
       %{conn: conn} do
    {sid, alice} = Fixtures.login("alice")
    {bob_sid, bob} = Fixtures.login("bob")

    {:ok, room} =
      Rooms.create_room(sid, alice, %{
        "name" => "Bygone room",
        "visibility" => "public",
        "tags" => "history"
      })

    :ok = Rooms.join(bob_sid, bob, Room.ref(room))
    :ok = Rooms.close_room(sid, alice, room)

    # anonymous: not a public room any more, not under its tag
    {:ok, _anon, html} = live(conn, ~p"/")
    refute html =~ "Bygone room"
    {:ok, _anon, html} = live(conn, ~p"/?tag=history")
    refute html =~ "Bygone room"

    # a stranger sees nothing either
    {other_sid, _} = Fixtures.login("carol")
    {:ok, _carol, html} = live(init_test_session(conn, Fixtures.cookie(other_sid)), ~p"/")
    refute html =~ "Bygone room"
    refute html =~ ~s(id="closed-rooms")

    # the creator and a former member find it under "Closed", nowhere else
    for cookie <- [Fixtures.cookie(sid), Fixtures.cookie(bob_sid)] do
      {:ok, view, html} = live(init_test_session(conn, cookie), ~p"/")
      assert has_element?(view, "#closed-rooms")
      assert has_element?(view, "#closed-rooms summary", "Closed")
      assert has_element?(view, "#closed-rooms", "Bygone room")
      # …and only there
      assert length(String.split(html, "Bygone room")) == 2
      assert has_element?(view, "#closed-rooms a span", "Closed")
    end
  end

  test "creating a room requires sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login?return_to=/rooms/new"}}} =
             live(conn, ~p"/rooms/new")
  end

  test "a revoked grant sends the creator to sign in again", %{conn: conn} do
    {sid, _alice} = Fixtures.login("alice")
    conn = init_test_session(conn, Fixtures.cookie(sid))
    {:ok, view, _html} = live(conn, ~p"/rooms/new")
    Fake.fail_next_under("/pub/pubky-rooms/rooms/", :unauthorized)

    view
    |> form("#new-room-form", room: %{name: "Gone", visibility: "public"})
    |> render_submit()

    {path, flash} = assert_redirect(view)
    assert path == ~p"/login"
    assert flash["error"] =~ "session has expired"

    # hand-crafted event payloads are ignored rather than crashing the view
    {:ok, view, _html} = live(conn, ~p"/rooms/new")
    render_hook(view, "tag_query", %{"q" => %{"nested" => true}})
    render_hook(view, "no_such_event", %{})
    assert has_element?(view, "#new-room-form")
  end

  test "a signed-in user creates a room and lands in it", %{conn: conn} do
    {sid, alice} = Fixtures.login("alice")
    conn = init_test_session(conn, Fixtures.cookie(sid))

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "No rooms yet"

    {:ok, view, _html} = live(conn, ~p"/rooms/new")
    assert has_element?(view, "#new-room-form")

    view
    |> form("#new-room-form", room: %{name: "", visibility: "public"})
    |> render_submit()

    assert render(view) =~ "Give the room a name of 1 to 64 characters."

    view
    |> form("#new-room-form", room: %{name: "Test room", topic: "Hello", visibility: "unlisted"})
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    %{created: [room]} = Directory.rooms_of(alice)
    assert room.name == "Test room"
    assert path == ~p"/r/#{alice}/#{room.id}"

    # both files landed on the homeserver
    files = Fake.files(alice)
    assert Map.has_key?(files, Paths.room(room.id))
    assert Map.has_key?(files, Paths.member({alice, room.id}))

    # the lobby now lists it
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Test room"
    assert html =~ "Unlisted"
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

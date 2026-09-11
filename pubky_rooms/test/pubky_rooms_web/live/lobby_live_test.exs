defmodule PubkyRoomsWeb.LobbyLiveTest do
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  import Phoenix.LiveViewTest

  alias PubkyRooms.Fixtures
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Directory, Paths}

  setup do
    reset_state()
  end

  test "anonymous visitors get the pitch and a sign-in link", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Sign in with Pubky Ring"
    refute has_element?(view, "#new-room")
  end

  test "creating a room requires sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login?return_to=/rooms/new"}}} =
             live(conn, ~p"/rooms/new")
  end

  test "a signed-in user creates a room and lands in it", %{conn: conn} do
    {sid, alice} = Fixtures.login("alice")
    conn = init_test_session(conn, Fixtures.cookie(sid))

    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No rooms yet"

    {:ok, view, _html} = live(conn, ~p"/rooms/new")
    assert has_element?(view, "#new-room-form")

    view
    |> form("#new-room-form", room: %{name: "", visibility: "public"})
    |> render_submit()

    assert render(view) =~ "must be 1 to 64 characters"

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
    assert html =~ "unlisted"
  end
end

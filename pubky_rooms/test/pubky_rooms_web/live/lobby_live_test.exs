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

  test "creating a room requires sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login?return_to=/rooms/new"}}} =
             live(conn, ~p"/rooms/new")
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

  defp wait_for(fun, pred, tries \\ 50) do
    value = fun.()

    cond do
      pred.(value) -> value
      tries == 0 -> flunk("condition not met; last value: #{inspect(value, limit: 300)}")
      true -> Process.sleep(20) && wait_for(fun, pred, tries - 1)
    end
  end
end

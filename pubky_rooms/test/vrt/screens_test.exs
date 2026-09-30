defmodule PubkyRoomsWeb.VRT.ScreensTest do
  @moduledoc """
  Visual regression: the key screens rendered in headless Chromium against the
  fakes and compared with the baselines in `test/vrt/snapshots`. The baselines
  come from CI's Chromium (the "VRT baselines" workflow regenerates them on
  the branch it is run from); a local run compares against those and writes a
  diff image to `test/vrt/snapshots/__diff__/` on a mismatch. A missing
  baseline is written and passes, so CI refuses a run that creates one.
  Excluded by default; `mix test --only vrt` runs it (same setup as `test/e2e`).

  Whatever varies between runs is masked (clock times in message rows, the
  sign-in QR code) or fixed (three named identities, seeded rooms and messages).
  """
  use PhoenixTest.Playwright.Case, async: false
  use PubkyRoomsWeb, :verified_routes

  import PubkyRooms.RoomsCase, only: [reset_state: 0]

  alias PubkyRooms.Auth.FakeGrantLogin
  alias PubkyRooms.E2E.Console
  alias PubkyRooms.Fixtures
  alias PubkyRooms.Profiles.LocalProfile
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms
  alias PubkyRooms.Rooms.{Message, Paths, Reaction, Room}

  @moduletag :vrt

  @desktop [viewport: %{width: 1280, height: 800}]
  @phone [has_touch: true, is_mobile: true, viewport: %{width: 390, height: 844}]
  # what changes between runs: message clock times
  @masks ["#messages time"]

  setup do
    reset_state()
    FakeGrantLogin.reset()
    Console.reset()
    # the test config bootstraps five messages; the room screen shows the whole conversation
    previous = Application.get_env(:pubky_rooms, :bootstrap_messages)
    Application.put_env(:pubky_rooms, :bootstrap_messages, 100)
    on_exit(fn -> Application.put_env(:pubky_rooms, :bootstrap_messages, previous) end)
    {:ok, seed()}
  end

  @tag browser_context_opts: @desktop
  test "signed out: the lobby and the sign-in page", %{conn: conn} do
    conn
    |> visit(~p"/")
    |> assert_has("#directory", text: "Lobby chatter")
    |> shoot("lobby-signed-out.png")
    |> visit(~p"/login")
    |> assert_has("body", text: "Waiting for approval")
    |> shoot("login.png", mask: [".qr"])

    assert Console.problems() == []
  end

  @tag browser_context_opts: @desktop
  test "signed in: the lobby, the new-room dialog and /me", %{conn: conn, alice: alice} do
    conn
    |> sign_in(alice)
    |> visit(~p"/")
    |> assert_has("main", text: "Your rooms")
    |> assert_has("#directory", text: "Lobby chatter")
    |> shoot("lobby-signed-in.png")
    |> visit(~p"/rooms/new")
    |> assert_has("#new-room-form")
    |> fill_in("Name", with: "Release notes")
    |> fill_in("Topic", with: "What shipped this week, one message per change.")
    |> click_button("Add a tag")
    |> fill_in("New tag", with: "releases")
    |> press("#new-room-tags-input", "Enter")
    |> assert_has("#new-room-tags", text: "releases")
    |> shoot("new-room.png")
    |> visit(~p"/me")
    |> assert_has("body", text: alice)
    |> shoot("me.png")

    assert Console.problems() == []
  end

  @tag browser_context_opts: @desktop
  test "a room with history, members and tags", %{conn: conn, alice: alice, path: path} do
    conn
    |> sign_in(alice)
    |> visit(path)
    |> assert_has("#messages > [id^='msg-']", count: 6)
    |> assert_has("aside", text: "Members · 3")
    |> shoot("room.png")

    assert Console.problems() == []
  end

  @tag browser_context_opts: @phone
  test "on a phone: the lobby and the room", %{conn: conn, alice: alice, path: path} do
    conn
    |> sign_in(alice)
    |> visit(~p"/")
    |> assert_has("#directory", text: "Lobby chatter")
    |> shoot("lobby-phone.png")
    |> visit(path)
    |> assert_has("#messages > [id^='msg-']", count: 6)
    |> shoot("room-phone.png")

    assert Console.problems() == []
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp sign_in(conn, z32) do
    conn = conn |> visit(~p"/login") |> assert_has("body", text: "Waiting for approval")
    FakeGrantLogin.resolve({:ok, Fixtures.session(z32)})
    assert_has(conn, "a[href='/me']")
  end

  # the LiveView connected and the webfonts loaded before the picture is taken
  defp shoot(conn, name, opts \\ []) do
    conn
    |> assert_has(".phx-connected")
    |> evaluate("document.fonts.ready.then(() => document.fonts.status)", &assert(&1 == "loaded"))
    |> assert_screenshot(
      name,
      Keyword.merge([full_page: false, mask: @masks, max_diff_pixel_ratio: 0.002], opts)
    )
  end

  # three named identities, three listed rooms, one of them with a conversation
  defp seed do
    {alice_sid, alice} = Fixtures.login("vrt-alice")
    {bob_sid, bob} = Fixtures.login("vrt-bob")
    {carol_sid, carol} = Fixtures.login("vrt-carol")

    for {z32, name} <- [{alice, "Alice"}, {bob, "Bob"}, {carol, "Carol"}],
        do: Fake.seed(z32, Paths.profile(), LocalProfile.encode(name))

    {:ok, room} =
      Rooms.create_room(alice_sid, alice, %{
        "name" => "Design critique",
        "topic" => "Screens, copy and the small things. Bring screenshots.",
        "visibility" => "public",
        "tags" => "design"
      })

    ref = Room.ref(room)
    {:ok, _} = Rooms.tag_room(alice_sid, alice, ref, "feedback")
    :ok = Rooms.join(bob_sid, bob, ref)
    :ok = Rooms.join(carol_sid, carol, ref)

    {:ok, builders} =
      Rooms.create_room(bob_sid, bob, %{
        "name" => "Pubky builders",
        "topic" => "Homeservers, PKARR, Nexus and the apps on top.",
        "visibility" => "public",
        "tags" => "pubky"
      })

    :ok = Rooms.join(alice_sid, alice, Room.ref(builders))

    {:ok, _chatter} =
      Rooms.create_room(carol_sid, carol, %{
        "name" => "Lobby chatter",
        "visibility" => "public",
        "tags" => "general"
      })

    lines = [
      {alice, "Welcome! Drop screens here and say what feels off."},
      {bob, "The lobby cards read well. The tag row on phones wraps twice though."},
      {carol, "Agreed on the tag row. Also: the composer hint could be shorter."},
      {alice, "It does now, each card scrolls inside.\nAlso here keeps its own height."},
      {carol, "Nice. Shipping it?"}
    ]

    [first | _] = messages = Enum.map(lines, fn {author, text} -> post(author, ref, text) end)
    last = List.last(messages)
    post(bob, ref, "Yes, right after the visual regression suite lands.", reply_to: last.uri)
    Fake.seed(bob, Paths.reaction(ref, alice, first.msg_id, "fire"), Reaction.encode())

    %{alice: alice, bob: bob, carol: carol, room: room, path: ~p"/r/#{alice}/#{room.id}"}
  end

  defp post(author, ref, text, opts \\ []) do
    {:ok, m} = Message.new(author, ref, text, opts)
    Fake.seed(author, Message.path(m), Message.encode(m))
    m
  end
end

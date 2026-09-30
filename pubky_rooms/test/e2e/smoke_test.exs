defmodule PubkyRoomsWeb.E2E.SmokeTest do
  @moduledoc """
  The checklist's smoke items in a real browser: headless Chromium through
  PhoenixTest's Playwright driver, against the fakes every other test uses
  (`Pubky.Fake` for the homeserver, `FakeGrantLogin` for the Ring flow).
  Excluded by default; `mix test --include e2e` runs it (needs `npm ci` in
  `assets` and `npx playwright install chromium`).
  """
  use PhoenixTest.Playwright.Case, async: false
  use PubkyRoomsWeb, :verified_routes

  import PubkyRooms.RoomsCase, only: [reset_state: 0]

  alias PhoenixTest.Playwright.Case, as: BrowserCase
  alias PubkyRooms.Auth.FakeGrantLogin
  alias PubkyRooms.E2E.Console
  alias PubkyRooms.Fixtures
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.Paths

  @moduletag :e2e

  setup do
    reset_state()
    FakeGrantLogin.reset()
    Console.reset()
    :ok
  end

  test "lobby, sign-in, open a room, send, a second identity joins and sees it live, /me",
       %{conn: alice_conn} = ctx do
    alice = Fixtures.z32("e2e-alice")
    bob = Fixtures.z32("e2e-bob")

    # signed-out lobby and the grant sign-in, landing back on the lobby
    alice_conn =
      alice_conn
      |> visit(~p"/")
      |> assert_has("main", text: "Group chat where every message is yours to keep")
      |> assert_has("#directory", text: "No rooms yet")
      |> click_link("Sign in with Pubky Ring")
      |> assert_has("body", text: "Waiting for approval")

    FakeGrantLogin.resolve({:ok, Fixtures.session(alice)})

    alice_conn =
      alice_conn
      |> assert_has("header a[href='/me']")
      |> assert_path(~p"/")
      |> refute_has("main", text: "Your rooms")

    # open a room: name, listed, one tag
    alice_conn =
      alice_conn
      |> click_link("aside a", "Open a room")
      |> assert_has("#new-room-form")
      |> fill_in("Name", with: "E2E room")
      |> fill_in("Topic", with: "The smoke pass in a real browser")
      |> click_button("Add a tag")
      |> fill_in("New tag", with: "e2e")
      |> press("#new-room-tags-input", "Enter")
      |> click_button("Open room")
      |> assert_has("[role='alert']", text: "Room opened. Copy the link to invite people.")
      |> assert_has("#composer")

    files = Map.keys(Fake.files(alice))
    [room_file] = Enum.filter(files, &String.starts_with?(&1, Paths.rooms_dir()))
    room_id = Path.basename(room_file)
    room_path = ~p"/r/#{alice}/#{room_id}"
    assert_path(alice_conn, room_path)
    assert Paths.member({alice, room_id}) in files
    assert Enum.any?(files, &String.starts_with?(&1, Paths.tags_dir()))

    # send: Enter sends, the row confirms, the composer clears and keeps focus
    alice_conn =
      alice_conn
      |> type("#composer-input", "hello from alice")
      |> press("#composer-input", "Enter")
      |> assert_has("#messages > [id^='msg-']", text: "hello from alice")
      |> assert_has("#messages [data-tip='Stored on your homeserver']")

    alice_conn
    |> evaluate("document.querySelector('#composer-input').value", &assert(&1 == ""))
    |> evaluate("document.activeElement.id", &assert(&1 == "composer-input"))

    # Shift+Enter breaks a line instead of sending
    alice_conn =
      alice_conn
      |> type("#composer-input", "line one")
      |> press("#composer-input", "Shift+Enter")
      |> type("#composer-input", "line two")

    evaluate(alice_conn, "document.querySelector('#composer-input').value", fn value ->
      assert value == "line one\nline two"
    end)

    alice_conn =
      alice_conn
      |> press("#composer-input", "Enter")
      |> assert_has("#messages > [id^='msg-']", text: "line two")

    assert [_, _] =
             alice
             |> Fake.files()
             |> Map.keys()
             |> Enum.filter(&String.starts_with?(&1, Paths.messages_dir({alice, room_id})))

    # the room is in Your rooms and the directory
    alice_conn
    |> visit(~p"/")
    |> assert_has("main", text: "Your rooms")
    |> assert_has("main a[href='#{room_path}']", text: "E2E room")

    # a second identity opens the link: history, join, a live reply
    [conn: bob_conn] = BrowserCase.do_setup(ctx)

    bob_conn =
      bob_conn
      |> visit(~p"/login")
      |> assert_has("body", text: "Waiting for approval")

    FakeGrantLogin.resolve({:ok, Fixtures.session(bob)})

    bob_conn =
      bob_conn
      |> assert_has("header a[href='/me']")
      |> visit(room_path)
      |> assert_has("#messages > [id^='msg-']", text: "hello from alice")
      |> assert_has("#messages > [id^='msg-']", text: "line two")
      |> refute_has("#composer")
      |> click_button("Join room")
      |> assert_has("[role='alert']", text: "You joined the room.")
      |> assert_has("#composer")
      |> type("#composer-input", "hi from bob")
      |> press("#composer-input", "Enter")
      |> assert_has("#messages > [id^='msg-']", text: "hi from bob")
      |> assert_has("#messages [id^='msg-#{bob}'] [data-tip='Stored on your homeserver']")

    alice_conn =
      alice_conn
      |> visit(room_path)
      |> assert_has("#messages > [id^='msg-']", text: "hi from bob")
      |> refute_has("#messages [id^='msg-#{bob}'] [data-tip='Stored on your homeserver']")

    # /me: the key with its copy button, the trust facts, sign out
    alice_conn
    |> visit(~p"/me")
    |> assert_has("body", text: alice)
    |> assert_has("button[aria-label='Copy your public key']")
    |> assert_has("body", text: "Signed in with")
    |> assert_has("body", text: "Access granted")
    |> assert_has("a[href='/logout']", text: "Sign out")

    # no console errors or warnings anywhere on the way (a CSP violation would be one)
    assert Console.problems() == []
    _ = bob_conn
  end

  @tag browser_context_opts: [
         has_touch: true,
         is_mobile: true,
         viewport: %{width: 375, height: 812}
       ]
  test "on a phone Enter inserts a newline and the button sends", %{conn: conn} do
    alice = Fixtures.z32("e2e-phone")

    conn =
      conn
      |> visit(~p"/login")
      |> assert_has("body", text: "Waiting for approval")

    FakeGrantLogin.resolve({:ok, Fixtures.session(alice)})

    conn =
      conn
      |> assert_path(~p"/")
      |> assert_has("a[href='/me']")
      |> visit(~p"/rooms/new")
      |> fill_in("Name", with: "Phone room")
      |> click_button("Open room")
      |> assert_has("#composer")
      |> type("#composer-input", "line one")
      |> press("#composer-input", "Enter")
      |> type("#composer-input", "line two")

    evaluate(conn, "document.querySelector('#composer-input').value", fn value ->
      assert value == "line one\nline two"
    end)

    conn
    |> refute_has("#messages > [id^='msg-']")
    |> click_button("Send")
    |> assert_has("#messages > [id^='msg-']", text: "line two")

    assert Console.problems() == []
  end
end

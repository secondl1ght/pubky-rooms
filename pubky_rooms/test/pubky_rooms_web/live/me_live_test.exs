defmodule PubkyRoomsWeb.MeLiveTest do
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  import Phoenix.LiveViewTest

  alias PubkyRooms.{Fixtures, Profiles}
  alias PubkyRooms.Profiles.LocalProfile
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.Paths

  setup %{conn: conn} do
    reset_state()
    {sid, user} = Fixtures.login("me")
    %{conn: init_test_session(conn, Fixtures.cookie(sid)), user: user}
  end

  test "anonymous visitors are sent to sign in" do
    assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), ~p"/me")
  end

  test "hand-crafted event payloads are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/me")
    render_hook(view, "save_nickname", %{"nickname" => %{"name" => ["not", "a", "string"]}})
    render_hook(view, "no_such_event", %{})
    assert render(view) =~ "Sign out"
  end

  test "the public key can be copied", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/me")
    assert has_element?(view, "#copy-pubky[data-copy='#{user}'][phx-hook='Clipboard']")
  end

  test "a nickname is written to the homeserver and shown everywhere", %{conn: conn, user: user} do
    {:ok, view, html} = live(conn, ~p"/me")
    assert html =~ "shown as your shortened key"
    assert html =~ Profiles.short_key(user)

    view |> form("#nickname-form", nickname: %{name: "  "}) |> render_submit()
    render_async(view)
    assert render(view) =~ "Enter a name."

    view |> form("#nickname-form", nickname: %{name: "Nakamoto"}) |> render_submit()
    render_async(view)
    assert {:ok, %{name: "Nakamoto"}} = LocalProfile.decode(Fake.files(user)[Paths.profile()])

    # the homeserver event refreshes the profile; the page updates in place
    html = wait_for(fn -> render(view) end, &(&1 =~ "Rooms nickname"))
    assert html =~ "Nakamoto"

    view |> element("button", "Remove") |> render_click()
    render_async(view)
    refute Map.has_key?(Fake.files(user), Paths.profile())
    wait_for(fn -> render(view) end, &(&1 =~ "shown as your shortened key"))
  end

  test "with a Pubky App profile the nickname form is hidden", %{conn: conn, user: user} do
    Fake.seed(user, Profiles.pubky_app_profile_path(), JSON.encode!(%{name: "App Name"}))
    Profiles.refresh(user)
    Profiles.subscribe()
    assert_receive {:profile_updated, ^user, %{name: "App Name"}}, 1_000

    {:ok, view, html} = live(conn, ~p"/me")
    assert html =~ "App Name"
    assert html =~ "from your Pubky App profile"
    refute has_element?(view, "#nickname-form")
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

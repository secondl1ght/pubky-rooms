defmodule PubkyRoomsWeb.AuthLiveTest do
  use PubkyRoomsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PubkyRooms.Auth.{FakeGrantLogin, SessionStore}
  alias PubkyRooms.{Fixtures, RateLimit}

  setup do
    RateLimit.reset()
    FakeGrantLogin.reset()
    :ok
  end

  test "shows the Ring deep link while waiting, then hands the browser its session", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login?return_to=/rooms/new")
    html = render(view)
    assert html =~ "Waiting for approval"
    assert html =~ ~s(data-copy="pubkyauth://signin_grant?)
    assert html =~ "Open in Pubky Ring"
    assert html =~ "<svg"
    assert FakeGrantLogin.flows() == 1

    user = Fixtures.z32("ring-user")
    FakeGrantLogin.resolve({:ok, Fixtures.session(user)})

    {path, _flash} = assert_redirect(view, 2_000)
    assert path =~ ~r{^/auth/complete\?return_to=%2Frooms%2Fnew&token=}

    # the handoff sets the cookie session and lands on return_to
    conn = get(conn, path)
    assert redirected_to(conn) == "/rooms/new"
    sid = get_session(conn, "sid")
    assert SessionStore.user_of(sid) == user
    assert get_session(conn, "cred") =~ "pubky-grant-credential-v1:"
  end

  test "an expired code offers a new one; errors are explained", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")
    FakeGrantLogin.resolve({:error, :expired})
    html = wait_for(fn -> render(view) end, &(&1 =~ "This code expired"))
    refute html =~ "Waiting for approval"
    assert has_element?(view, "button", "New code")

    view |> element("button", "New code") |> render_click()
    assert render(view) =~ "Waiting for approval"
    assert FakeGrantLogin.flows() == 2

    FakeGrantLogin.resolve({:error, {:transport, :econnrefused}})
    assert wait_for(fn -> render(view) end, &(&1 =~ "could not be reached"))

    view |> element("button", "New code") |> render_click()
    FakeGrantLogin.resolve({:error, :cnf_mismatch})
    assert wait_for(fn -> render(view) end, &(&1 =~ "different request"))
  end

  test "sign-in starts are rate-limited per client (20 per minute)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/login")

    for _ <- 1..19 do
      FakeGrantLogin.resolve({:error, :expired})
      wait_for(fn -> render(view) end, &(&1 =~ "This code expired"))
      view |> element("button", "New code") |> render_click()
    end

    FakeGrantLogin.resolve({:error, :expired})
    wait_for(fn -> render(view) end, &(&1 =~ "This code expired"))
    view |> element("button", "New code") |> render_click()
    assert render(view) =~ "Too many sign-in attempts"
  end

  defp wait_for(fun, pred, tries \\ 100) do
    value = fun.()

    cond do
      pred.(value) -> value
      tries == 0 -> flunk("condition not met; last value: #{inspect(value, limit: 300)}")
      true -> Process.sleep(20) && wait_for(fun, pred, tries - 1)
    end
  end
end

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

  test "people without an account get an onboarding hint, highlighted when the key has no homeserver",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/login")
    # the hint is always there, quietly
    assert has_element?(view, "#onboarding", "New to Pubky?")
    assert html =~ ~s(href="https://pubky.app")
    assert html =~ ~s(href="https://pubkyring.app")
    refute has_element?(view, "#onboarding.ring-1")

    # Ring approved with a key that never signed up anywhere
    FakeGrantLogin.resolve({:error, :homeserver_unresolved})
    html = wait_for(fn -> render(view) end, &(&1 =~ "no homeserver yet"))
    assert html =~ "Rooms cannot create one"
    assert has_element?(view, "#onboarding.ring-1")

    # the homeserver does not know the key either
    view |> element("button", "New code") |> render_click()
    refute has_element?(view, "#onboarding.ring-1")
    FakeGrantLogin.resolve({:error, {:exchange, {:http, 404, "unknown user"}}})
    html = wait_for(fn -> render(view) end, &(&1 =~ "did not accept the sign-in"))
    assert html =~ "status 404"
    assert has_element?(view, "#onboarding.ring-1")

    # other failures are explained without pointing at onboarding
    view |> element("button", "New code") |> render_click()
    FakeGrantLogin.resolve({:error, {:exchange, {:transport, :timeout}}})
    assert wait_for(fn -> render(view) end, &(&1 =~ "could not be reached"))
    refute has_element?(view, "#onboarding.ring-1")

    view |> element("button", "New code") |> render_click()
    FakeGrantLogin.resolve({:error, {:relay, :econnrefused}})
    assert wait_for(fn -> render(view) end, &(&1 =~ "relay could not be reached"))
  end

  test "the staging stack carries a notice to sign in with a staging identity", %{conn: conn} do
    # the default stack (testnet here, mainnet in production) shows no notice
    {:ok, view, _html} = live(conn, ~p"/login")
    refute has_element?(view, "#staging-notice")

    stack = Application.get_env(:pubky_rooms, :pubky_stack)
    app_url = Application.get_env(:pubky_rooms, :pubky_app_url)

    on_exit(fn ->
      Application.put_env(:pubky_rooms, :pubky_stack, stack)
      Application.put_env(:pubky_rooms, :pubky_app_url, app_url)
    end)

    Application.put_env(:pubky_rooms, :pubky_stack, :staging)
    Application.put_env(:pubky_rooms, :pubky_app_url, "https://staging.pubky.app")

    {:ok, view, _html} = live(conn, ~p"/login")
    assert has_element?(view, "#staging-notice", "This is the staging deployment.")
    assert has_element?(view, "#staging-notice", "production identities may not work here")

    assert has_element?(
             view,
             ~s(#staging-notice a[href="https://staging.pubky.app"]),
             "staging.pubky.app"
           )

    # the onboarding footer stays next to it
    assert has_element?(view, "#onboarding", "New to Pubky?")
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

  test "behind a proxy the limiter keys on the client named by x-forwarded-for", %{conn: conn} do
    # Fly appends its own address last; the client is the entry before it
    forwarded = fn ip ->
      Plug.Conn.put_private(conn, :live_view_connect_info, %{
        x_headers: [{"x-forwarded-for", "10.0.0.9, #{ip}, 66.241.124.1"}],
        peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil}
      })
    end

    conn_a = forwarded.("203.0.113.5")
    conn_b = forwarded.("198.51.100.7")

    {:ok, view, _html} = live(conn_a, ~p"/login")

    for _ <- 1..20 do
      FakeGrantLogin.resolve({:error, :expired})
      wait_for(fn -> render(view) end, &(&1 =~ "This code expired"))
      view |> element("button", "New code") |> render_click()
    end

    assert render(view) =~ "Too many sign-in attempts"

    # another client behind the same proxy is not affected
    {:ok, other, _html} = live(conn_b, ~p"/login")
    assert render(other) =~ "Waiting for approval"
    refute render(other) =~ "Too many sign-in attempts"
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

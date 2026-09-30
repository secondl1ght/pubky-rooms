defmodule PubkyRoomsWeb.AuthLive do
  @moduledoc """
  Sign in with Pubky Ring.

  On connect the LiveView starts a grant flow, shows its `pubkyauth://` URL as
  a QR code (and as a link for phones), and waits for the approval in a task.
  When the session arrives it is stored and the browser is redirected to
  `/auth/complete`, which sets the cookie.
  """
  use PubkyRoomsWeb, :live_view

  alias PubkyRooms.Auth.{GrantLogin, SessionStore}
  alias PubkyRooms.RateLimit
  alias PubkyRoomsWeb.{AuthController, UserAuth}

  on_mount {PubkyRoomsWeb.UserAuth, :redirect_if_authenticated}

  @approval_timeout 180_000

  # `config :pubky_rooms, :grant_login` swaps in a test double for the Ring flow.
  defp grant_login, do: Application.get_env(:pubky_rooms, :grant_login, GrantLogin)

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Sign in",
        page_description:
          "Sign in with Pubky Ring to open and join live rooms. Rooms asks for one folder on your homeserver and nothing else.",
        return_to: UserAuth.safe_return_to(params["return_to"]),
        state: :starting,
        auth_url: nil,
        qr_svg: nil,
        error: nil,
        no_account: false,
        network: Pubky.Config.get().network,
        simulator_url: Application.get_env(:pubky_rooms, :simulator_url),
        pubky_app_url: Application.get_env(:pubky_rooms, :pubky_app_url),
        pubky_ring_url: Application.get_env(:pubky_rooms, :pubky_ring_url),
        # connect info is only readable during mount; "New code" needs it later.
        # Only a keyed hash of the client address is kept, and only in memory
        # for the rate-limit window (ADR 0006: no addresses stored or logged).
        client_key: client_key(socket)
      )

    if connected?(socket), do: {:ok, start_flow(socket)}, else: {:ok, socket}
  end

  @impl true
  def handle_event("new_code", _params, socket), do: {:noreply, start_flow(socket)}

  @impl true
  def handle_async(:await, {:ok, {:ok, session}}, socket) do
    sid = SessionStore.put(session)
    token = AuthController.handoff_token(sid)

    {:noreply,
     redirect(socket,
       to: ~p"/auth/complete?#{[token: token, return_to: socket.assigns.return_to]}"
     )}
  end

  def handle_async(:await, {:ok, {:error, :expired}}, socket) do
    {:noreply, assign(socket, state: :expired)}
  end

  def handle_async(:await, {:ok, {:error, reason}}, socket) do
    {:noreply,
     assign(socket, state: :error, error: describe(reason), no_account: no_account?(reason))}
  end

  def handle_async(:await, {:exit, reason}, socket) do
    {:noreply, assign(socket, state: :error, error: describe(reason), no_account: false)}
  end

  defp start_flow(socket) do
    case RateLimit.check({:login, socket.assigns.client_key}, 20, 60_000) do
      :ok ->
        login = grant_login()
        flow = login.start()
        url = login.authorization_url(flow)

        socket
        |> assign(
          state: :waiting,
          auth_url: url,
          qr_svg: qr_svg(url),
          error: nil,
          no_account: false
        )
        |> start_async(:await, fn -> login.await(flow, @approval_timeout) end)

      {:error, {:rate_limited, _}} ->
        assign(socket, state: :error, error: "Too many sign-in attempts. Please wait a minute.")
    end
  end

  # Behind a proxy (Fly) the peer is the proxy, so the client comes from
  # `x-forwarded-for` (Phoenix only exposes `x-` headers to LiveViews, so
  # `fly-client-ip` is out of reach). Fly appends its own address last, so the
  # client is the entry before it; anything earlier was supplied by the client
  # and is ignored. Hashed with the app secret so the address itself never
  # sits in the rate-limit table.
  defp client_key(socket) do
    headers = get_connect_info(socket, :x_headers) || []

    address =
      case List.keyfind(headers, "x-forwarded-for", 0) do
        {_, value} when is_binary(value) ->
          forwarded_client(value) || peer_address(socket)

        _ ->
          peer_address(socket)
      end

    secret = PubkyRoomsWeb.Endpoint.config(:secret_key_base)
    :crypto.mac(:hmac, :sha256, secret, address) |> binary_part(0, 16)
  end

  defp forwarded_client(value) do
    case value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      [only] -> only
      entries -> Enum.at(entries, -2)
    end
  end

  defp peer_address(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> :inet.ntoa(address) |> to_string()
      _ -> "unknown"
    end
  end

  # `<.link>` only accepts known schemes as strings; custom ones are passed as a tuple.
  defp deep_link("pubkyauth://" <> rest), do: {:pubkyauth, "//" <> rest}
  defp deep_link(url), do: url

  defp qr_svg(url) do
    url
    |> EQRCode.encode(:q)
    |> EQRCode.svg(color: "#05050A", background_color: "#FFFFFF", viewbox: true)
    |> Phoenix.HTML.raw()
  end

  # `Pubky.Auth.GrantFlow` failures, in the words of someone signing in. The
  # two "no account" cases point at the onboarding hint below the card.
  defp describe(:expired), do: "The code expired."

  defp describe(:homeserver_unresolved),
    do:
      "This key has no homeserver yet, so there is no account to sign in to. " <>
        "Rooms cannot create one: set up your identity with Pubky Ring and Pubky App first (see below), then try again."

  defp describe({:exchange, {:http, status, _}}) when status in [401, 403, 404],
    do:
      "Your homeserver did not accept the sign-in (status #{status}). " <>
        "If this key never signed up there, do that in Pubky App first (see below)."

  defp describe({:exchange, {:http, status, _}}),
    do: "Your homeserver answered with status #{status}. Try again in a moment."

  defp describe({:exchange, {:transport, _}}), do: "Your homeserver could not be reached."
  defp describe({:exchange, reason}), do: describe(reason)
  defp describe({:relay, _}), do: "The Pubky Ring relay could not be reached. Try again."
  defp describe(:decrypt), do: "Pubky Ring's answer could not be read. Generate a new code."
  defp describe(:grant_mismatch), do: "Pubky Ring answered for a different request."
  defp describe({:http, status, _}), do: "The homeserver answered with status #{status}."
  defp describe({:transport, _}), do: "The homeserver could not be reached."
  defp describe(:cnf_mismatch), do: "Pubky Ring answered for a different request."
  defp describe(:client_id_mismatch), do: "Pubky Ring answered for a different app."
  defp describe(reason), do: "Sign-in failed (#{inspect(reason)})."

  # Sign-in failed because the key has no usable account: highlight onboarding.
  defp no_account?(:homeserver_unresolved), do: true
  defp no_account?({:exchange, {:http, status, _}}) when status in [401, 403, 404], do: true
  defp no_account?(_reason), do: false

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.container class="pb-24 pt-4 lg:pb-12">
        <div class="mx-auto flex max-w-5xl flex-col gap-8 lg:flex-row lg:items-start lg:gap-12">
          <div class="flex flex-1 flex-col gap-4 lg:pt-10">
            <.typography size="2xl" tag="h1">
              Sign in to<br />Pubky <span class="text-brand">Rooms.</span>
            </.typography>
            <.typography size="md" class="max-w-md text-muted-foreground">
              Scan the code with Pubky Ring to approve Rooms. It asks for one folder on your homeserver
              and nothing else. Everything you write here is stored there, under your keys.
            </.typography>
            <ul class="mt-2 flex flex-col gap-2 text-sm text-secondary-foreground">
              <li class="flex items-center gap-2">
                <.icon name="lucide-folder-key" class="size-4 text-brand" /> Access limited to
                <code class="rounded bg-secondary px-1.5 py-0.5 text-xs">/pub/pubky-rooms/</code>
              </li>
              <li class="flex items-center gap-2">
                <.icon name="lucide-shield-check" class="size-4 text-brand" />
                Your keys never leave Pubky Ring
              </li>
              <li class="flex items-center gap-2">
                <.icon name="lucide-log-out" class="size-4 text-brand" />
                Revoke access any time from Ring
              </li>
              <li class="flex items-center gap-2">
                <.icon name="lucide-cookie" class="size-4 text-brand" />
                Your grant lives in your browser; the server forgets it when you leave
              </li>
              <li class="flex items-center gap-2">
                <.icon name="lucide-globe" class="size-4 text-brand" /> All rooms are public
              </li>
              <li class="flex items-center gap-2">
                <.icon name="lucide-eye-off" class="size-4 text-brand" /> No analytics or tracking
              </li>
            </ul>
          </div>

          <.card class="w-full max-w-md gap-5 self-center lg:self-start">
            <.card_header>
              <.card_title>Pubky Ring</.card_title>
              <.card_description>
                <%= case @state do %>
                  <% :waiting -> %>
                    Scan with the Pubky Ring app, or open the link on this device.
                  <% :expired -> %>
                    This code expired. Generate a new one to try again.
                  <% :error -> %>
                    {@error}
                  <% _ -> %>
                    Preparing your sign-in code…
                <% end %>
              </.card_description>
            </.card_header>

            <.card_content class="flex flex-col items-center gap-5">
              <div class="relative aspect-square w-full max-w-[280px] overflow-hidden rounded-xl bg-white p-3">
                <div :if={@qr_svg && @state == :waiting} class="qr size-full [&_svg]:size-full">
                  {@qr_svg}
                </div>
                <div
                  :if={@state == :waiting}
                  class="absolute inset-0 flex items-center justify-center"
                >
                  <span class="flex size-14 items-center justify-center rounded-xl bg-white shadow-md">
                    <.pubky_mark class="size-10 [&]:brightness-0" />
                  </span>
                </div>
                <div
                  :if={@state != :waiting}
                  class="flex size-full flex-col items-center justify-center gap-3 rounded-lg bg-background/5 text-background"
                >
                  <.spinner :if={@state == :starting} class="size-8" />
                  <.icon
                    :if={@state in [:expired, :error]}
                    name="lucide-timer-off"
                    class="size-10 opacity-60"
                  />
                  <.button :if={@state in [:expired, :error]} variant="secondary" phx-click="new_code">
                    <.icon name="lucide-refresh-cw" class="size-4" /> New code
                  </.button>
                </div>
              </div>

              <div
                :if={@state == :waiting}
                class="flex items-center gap-2 text-sm text-muted-foreground"
              >
                <.spinner class="size-4" /> Waiting for approval…
              </div>

              <div :if={@state == :waiting} class="flex w-full flex-col gap-2 sm:flex-row">
                <.button variant="brand" href={deep_link(@auth_url)} class="flex-1">
                  <.icon name="lucide-smartphone" class="size-4" /> Open in Pubky Ring
                </.button>
                <.button
                  variant="secondary"
                  class="flex-1"
                  id="copy-auth-url"
                  phx-hook="Clipboard"
                  data-copy={@auth_url}
                >
                  <.icon name="lucide-copy" class="size-4" /> Copy link
                </.button>
              </div>
            </.card_content>

            <.card_footer>
              <div
                id="onboarding"
                class={[
                  "flex w-full flex-col items-start gap-2 rounded-lg p-4 text-sm",
                  @no_account && "bg-brand/10 ring-1 ring-brand/40",
                  !@no_account && "bg-secondary/40"
                ]}
              >
                <p class="flex items-center gap-2 font-semibold text-secondary-foreground">
                  <.icon name="lucide-sparkles" class="size-4 text-brand" /> New to Pubky?
                </p>
                <p class="text-muted-foreground">
                  Get your keys with the
                  <a
                    href={@pubky_ring_url}
                    target="_blank"
                    rel="noopener"
                    class="text-brand hover:underline"
                  >Pubky Ring</a>
                  app, sign up for a homeserver in
                  <a
                    href={@pubky_app_url}
                    target="_blank"
                    rel="noopener"
                    class="text-brand hover:underline"
                  >Pubky App</a>
                  then come back and scan this code. One identity works in every Pubky client.
                </p>
              </div>
            </.card_footer>

            <.card_footer :if={@network == :testnet} class="text-xs text-muted-foreground">
              <p>
                Testnet: approve with the
                <a
                  :if={@simulator_url}
                  href={@simulator_url}
                  target="_blank"
                  rel="noopener"
                  class="text-brand hover:underline"
                >
                  Pubky Ring Simulator
                </a>
                <span :if={!@simulator_url}>Pubky Ring Simulator</span>
                (paste the copied link into Shortcut mode).
              </p>
            </.card_footer>
          </.card>
        </div>
      </.container>
    </Layouts.app>
    """
  end
end

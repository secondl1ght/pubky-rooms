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
        return_to: UserAuth.safe_return_to(params["return_to"]),
        state: :starting,
        auth_url: nil,
        qr_svg: nil,
        error: nil,
        network: Pubky.Config.get().network,
        simulator_url: Application.get_env(:pubky_rooms, :simulator_url),
        # connect info is only readable during mount; "New code" needs it later
        peer_ip: peer_ip(socket)
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
    {:noreply, assign(socket, state: :error, error: describe(reason))}
  end

  def handle_async(:await, {:exit, reason}, socket) do
    {:noreply, assign(socket, state: :error, error: describe(reason))}
  end

  defp start_flow(socket) do
    case RateLimit.check({:login, socket.assigns.peer_ip}, 10, 60_000) do
      :ok ->
        login = grant_login()
        flow = login.start()
        url = login.authorization_url(flow)

        socket
        |> assign(state: :waiting, auth_url: url, qr_svg: qr_svg(url), error: nil)
        |> start_async(:await, fn -> login.await(flow, @approval_timeout) end)

      {:error, {:rate_limited, _}} ->
        assign(socket, state: :error, error: "Too many sign-in attempts. Please wait a minute.")
    end
  end

  defp peer_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: address} -> address
      _ -> :unknown
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

  defp describe(:expired), do: "The code expired."
  defp describe({:http, status, _}), do: "The homeserver answered with status #{status}."
  defp describe({:transport, _}), do: "The homeserver could not be reached."
  defp describe(:cnf_mismatch), do: "Pubky Ring answered for a different request."
  defp describe(:client_id_mismatch), do: "Pubky Ring answered for a different app."
  defp describe(reason), do: "Sign-in failed (#{inspect(reason)})."

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
              Scan the code with Pubky Ring to approve this app. Rooms only asks for its own
              folder on your homeserver, and every message you send is stored there, under your keys.
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
                Your grant stays in this browser; this server keeps nothing on disk
              </li>
              <li class="flex items-center gap-2">
                <.icon name="lucide-globe" class="size-4 text-brand" /> All rooms are public
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
                  <.button :if={@state in [:expired, :error]} variant="dark" phx-click="new_code">
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

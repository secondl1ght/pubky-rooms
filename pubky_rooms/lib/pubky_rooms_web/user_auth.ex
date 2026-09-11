defmodule PubkyRoomsWeb.UserAuth do
  @moduledoc """
  Resolves the signed-in user from the cookie session.

  The encrypted cookie carries the session id, the user's public key and their
  Pubky credential (see `PubkyRooms.Auth.SessionStore`). Both the plug (for
  controllers) and the `on_mount` hooks (for LiveViews) re-seed the in-memory
  session cache from it and assign:

    * `:current_user` — `%{pubky, name, avatar_url}` or `nil`
    * `:sid` — the session id, used for homeserver writes

  Resolving a user never touches the network: the credential is only exercised
  on the first write, which reports `:unauthorized` if the grant is gone.
  The credential itself is never assigned to a socket or conn.
  """
  use PubkyRoomsWeb, :verified_routes

  import Plug.Conn

  alias Phoenix.LiveView
  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Profiles

  @doc "Plug: assigns `current_user` and `sid` from the session cookie."
  def fetch_current_user(conn, _opts) do
    {sid, user} = resolve(get_session(conn))

    conn
    |> assign(:current_user, user)
    |> assign(:sid, sid)
  end

  @doc """
  LiveView `on_mount` hooks.

    * `:mount_current_user` — assigns the user (or nil) and, once connected,
      wires the user's live subscriptions
    * `:require_authenticated` — redirects anonymous visitors to `/login`
    * `:redirect_if_authenticated` — sends signed-in users away from `/login`
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       socket
       |> LiveView.put_flash(:error, "Sign in to continue.")
       |> LiveView.redirect(to: ~p"/login")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns.current_user,
      do: {:halt, LiveView.redirect(socket, to: ~p"/")},
      else: {:cont, socket}
  end

  defp mount_current_user(socket, session) do
    {sid, user} = resolve(session)

    socket =
      socket
      |> Phoenix.Component.assign(:current_user, user)
      |> Phoenix.Component.assign(:sid, sid)

    if user && LiveView.connected?(socket) do
      SessionStore.touch(sid)
      SessionStore.attach(sid)
      PubkyRooms.Rooms.on_user_connected(user.pubky)
    end

    socket
  end

  # Re-seeds the session cache from cookie values and returns `{sid, user}`.
  defp resolve(session) when is_map(session) do
    with sid when is_binary(sid) <- SessionStore.ensure(session),
         pubky when is_binary(pubky) <- SessionStore.user_of(sid) do
      {sid, Profiles.get(pubky)}
    else
      _ -> {nil, nil}
    end
  end

  defp resolve(_), do: {nil, nil}

  @doc "Only local paths are accepted as post-login destinations."
  @spec safe_return_to(term()) :: String.t()
  def safe_return_to("/" <> rest = path) when byte_size(path) < 512 do
    if String.starts_with?(rest, "/") or String.contains?(rest, "\\"), do: "/", else: path
  end

  def safe_return_to(_), do: "/"
end

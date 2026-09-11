defmodule PubkyRoomsWeb.UserAuth do
  @moduledoc """
  Resolves the signed-in user from the cookie session.

  The cookie holds only an opaque session id (`sid`); everything else lives in
  `PubkyRooms.Auth.SessionStore`. Both the plug (for controllers) and the
  `on_mount` hooks (for LiveViews) assign:

    * `:current_user` — `%{pubky, name, avatar_url}` or `nil`
    * `:sid` — the session id, used for homeserver writes

  Resolving a user never touches the network: credentials are only exercised
  on the first write, which reports `:unauthorized` if the grant is gone.
  """
  use PubkyRoomsWeb, :verified_routes

  import Plug.Conn

  alias Phoenix.LiveView
  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Profiles

  @doc "Plug: assigns `current_user` and `sid` from the session cookie."
  def fetch_current_user(conn, _opts) do
    sid = get_session(conn, :sid)
    user = current_user(sid)
    if user, do: SessionStore.touch(sid)

    conn
    |> assign(:current_user, user)
    |> assign(:sid, if(user, do: sid))
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
    sid = session["sid"]
    user = current_user(sid)

    socket =
      socket
      |> Phoenix.Component.assign(:current_user, user)
      |> Phoenix.Component.assign(:sid, if(user, do: sid))

    if user && LiveView.connected?(socket) do
      SessionStore.touch(sid)
      PubkyRooms.Rooms.on_user_connected(user.pubky)
    end

    socket
  end

  @doc "The user behind a session id, or nil."
  @spec current_user(term()) :: Profiles.profile() | nil
  def current_user(sid) do
    case SessionStore.user_of(sid) do
      nil -> nil
      pubky -> Profiles.get(pubky)
    end
  end

  @doc "Only local paths are accepted as post-login destinations."
  @spec safe_return_to(term()) :: String.t()
  def safe_return_to("/" <> rest = path) when byte_size(path) < 512 do
    if String.starts_with?(rest, "/") or String.contains?(rest, "\\"), do: "/", else: path
  end

  def safe_return_to(_), do: "/"
end

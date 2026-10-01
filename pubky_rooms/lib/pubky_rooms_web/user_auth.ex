defmodule PubkyRoomsWeb.UserAuth do
  @moduledoc """
  Resolves the signed-in user from the cookie session.

  The encrypted cookie carries the session id, the user's public key and their
  Pubky credential (see `PubkyRooms.Auth.SessionStore`). Both the plug (for
  controllers) and the `on_mount` hooks (for LiveViews) re-seed the in-memory
  session cache from it and assign:

    * `:current_user` — `%{pubky, name, avatar_url, source}` or `nil`
    * `:sid` — the session id, used for homeserver writes

  Resolving a user never touches the network: the credential is only exercised
  on the first write, which reports `:unauthorized` if the grant is gone. Once
  a grant is known to be revoked or expired, the plug drops the cookie on the
  next request, so the browser is signed out instead of looking signed in.
  The credential itself is never assigned to a socket or conn.
  """
  use PubkyRoomsWeb, :verified_routes

  import Plug.Conn

  alias Phoenix.LiveView
  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Profiles

  @doc """
  Plug: assigns `current_user` and `sid` from the session cookie. A cookie
  whose grant turned out revoked is dropped here (LiveViews cannot set cookies).
  """
  def fetch_current_user(conn, _opts) do
    case resolve(get_session(conn)) do
      {:revoked, _sid} ->
        conn
        |> configure_session(drop: true)
        |> assign(:current_user, nil)
        |> assign(:sid, nil)

      {sid, user} ->
        conn
        |> assign(:current_user, user)
        |> assign(:sid, sid)
    end
  end

  @doc """
  LiveView `on_mount` hooks.

    * `:mount_current_user` — assigns the user (or nil) and, once connected,
      wires the user's live subscriptions, tracks app-wide presence and keeps
      `current_user` fresh on profile updates
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

  # Idempotent: a LiveView may run both the session-wide hook and its own.
  defp mount_current_user(%{assigns: %{sid: _}} = socket, _session), do: socket

  defp mount_current_user(socket, session) do
    {sid, user} =
      case resolve(session) do
        {:revoked, _sid} -> {nil, nil}
        resolved -> resolved
      end

    socket =
      socket
      |> Phoenix.Component.assign(:current_user, user)
      |> Phoenix.Component.assign(:sid, sid)

    if LiveView.connected?(socket) do
      if user do
        SessionStore.touch(sid)
        SessionStore.attach(sid)
        PubkyRooms.Rooms.on_user_connected(user.pubky)
        PubkyRoomsWeb.Presence.track_lobby(user)
      end

      # every connected viewer, signed in or not: profiles arrive after the
      # first paint when the cache is cold (members, Also here, lobby cards)
      Profiles.subscribe()
      LiveView.attach_hook(socket, :own_profile, :handle_info, &own_profile_hook/2)
    else
      socket
    end
  end

  # Keeps `current_user` current when the user's own profile changes; the
  # message continues to the LiveView, which may track other profiles too.
  defp own_profile_hook(
         {:profile_updated, z32, profile},
         %{assigns: %{current_user: %{pubky: z32}}} = socket
       ) do
    {:cont, Phoenix.Component.assign(socket, :current_user, profile)}
  end

  defp own_profile_hook(_msg, socket), do: {:cont, socket}

  # Re-seeds the session cache from cookie values and returns `{sid, user}`,
  # `{nil, nil}` for no or malformed cookie, `{:revoked, sid}` when the grant
  # behind the cookie is known to be gone.
  defp resolve(session) when is_map(session) do
    case SessionStore.ensure(session) do
      nil ->
        {nil, nil}

      sid ->
        case SessionStore.user_of(sid) do
          nil -> {:revoked, sid}
          pubky -> {sid, Profiles.get(pubky)}
        end
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

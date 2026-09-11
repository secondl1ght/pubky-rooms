defmodule PubkyRoomsWeb.AuthController do
  @moduledoc """
  Cookie handoff for sign-in and sign-out.

  `AuthLive` completes the Pubky Ring flow over the LiveView socket, where it
  cannot set cookies, so it redirects here with a short-lived, single-use
  `Phoenix.Token` naming the new session id. `complete/2` verifies it and
  writes the session (sid, public key and the Pubky credential) into the
  encrypted, signed, httpOnly cookie. The credential never appears in a URL.
  """
  use PubkyRoomsWeb, :controller

  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.RateLimit
  alias PubkyRoomsWeb.UserAuth

  @salt "auth-handoff"
  @max_age 60

  @doc "Signs a handoff token for a session id (used by `AuthLive`)."
  @spec handoff_token(String.t()) :: String.t()
  def handoff_token(sid), do: Phoenix.Token.sign(PubkyRoomsWeb.Endpoint, @salt, sid)

  def complete(conn, params) do
    token = params["token"] || ""

    with {:ok, sid} <-
           Phoenix.Token.verify(PubkyRoomsWeb.Endpoint, @salt, token, max_age: @max_age),
         :ok <- RateLimit.check({:handoff, token}, 1, @max_age * 1000),
         %{} = values <- SessionStore.cookie_session(sid) do
      conn
      |> configure_session(renew: true)
      |> put_cookie_session(values)
      |> put_flash(:success, "Signed in with Pubky Ring.")
      |> redirect(to: UserAuth.safe_return_to(params["return_to"]))
    else
      _ ->
        conn
        |> put_flash(:error, "That sign-in link is no longer valid. Please try again.")
        |> redirect(to: ~p"/login")
    end
  end

  def logout(conn, _params) do
    if sid = get_session(conn, "sid"), do: SessionStore.delete(sid)

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end

  defp put_cookie_session(conn, values) do
    Enum.reduce(values, conn, fn {key, value}, acc -> put_session(acc, key, value) end)
  end
end

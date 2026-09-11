defmodule PubkyRooms.Fixtures do
  @moduledoc "Test data helpers: fake users and login sessions."

  alias Pubky.Auth.Credential
  alias Pubky.Session
  alias PubkyRooms.Auth.SessionStore

  @homeserver "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"

  @doc "A deterministic z32-shaped public key derived from a short label."
  def z32(label) do
    alphabet = ~c"ybndrfg8ejkmcpqxot1uwisza345h769"

    :sha256
    |> :crypto.hash(label)
    |> :binary.bin_to_list()
    |> Stream.cycle()
    |> Enum.take(52)
    |> Enum.map(&Enum.at(alphabet, rem(&1, 32)))
    |> List.to_string()
  end

  @doc "A `%Pubky.Session{}` for `user` that never needs a refresh (no network)."
  def session(user) do
    %Session{
      user: user,
      homeserver: @homeserver,
      base_url: "http://localhost:6286",
      features: [],
      token: "tok-" <> user,
      token_expires_at: System.os_time(:second) + 86_400,
      grant_expires_at: System.os_time(:second) + 86_400 * 365,
      grant_id: "grant-" <> user,
      client_id: "rooms.test",
      capabilities: [],
      created_at: System.os_time(:second),
      credential: %Credential{
        grant_jws: "e30.e30.c2ln",
        client_secret: :crypto.strong_rand_bytes(32),
        homeserver: @homeserver
      }
    }
  end

  @doc "Stores a session for `user` and returns `{sid, user}`."
  def login(label \\ "alice") do
    user = z32(label)
    {SessionStore.put(session(user)), user}
  end

  @doc "The browser session (cookie values) for a sid, for `Plug.Test.init_test_session/2`."
  def cookie(sid), do: SessionStore.cookie_session(sid)
end

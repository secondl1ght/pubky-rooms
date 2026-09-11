defmodule Pubky.Auth.Pop do
  @moduledoc """
  Proof of possession: a short-lived JWS signed by the **client** key bound in
  a grant's `cnf` claim, proving to a specific homeserver that the caller holds
  that key. Claims: `aud` (homeserver pubky), `gid` (grant id), `nonce`, `iat`.

  Homeservers accept an `iat` within ±180 seconds of their clock and reject
  replayed nonces, so a fresh proof is signed for every exchange or refresh.
  """

  alias Pubky.Auth.Jws
  alias Pubky.Crypto.B64
  alias Pubky.{Keypair, PublicKey}

  @typ "pubky-pop"

  @doc "The JWS `typ` for proofs."
  def typ, do: @typ

  @doc "Signs a proof for `homeserver` and `grant_id`."
  @spec sign(Keypair.t(), PublicKey.z32(), String.t(), keyword()) :: String.t()
  def sign(%Keypair{} = client, homeserver, grant_id, opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    nonce = Keyword.get(opts, :nonce, B64.random_id())

    Jws.sign(client, @typ, [
      {"aud", homeserver},
      {"gid", grant_id},
      {"nonce", nonce},
      {"iat", now}
    ])
  end
end

defmodule Pubky.Auth.Credential do
  @moduledoc """
  The durable part of a grant-backed session: the grant JWS, the client
  (proof-of-possession) secret key, and the homeserver it was issued for.

  Bearer tokens last an hour and are never persisted; a credential mints a
  fresh one on `restore/2`. Treat exported credentials as bearer-equivalent
  secrets until the grant expires or is revoked. The export format is the one
  the official SDK uses, so credentials are portable.
  """

  alias Pubky.Auth.{Exchange, Grant}
  alias Pubky.{Config, Keypair, PublicKey, Session}
  alias Pubky.Crypto.{B64, Ed25519}

  @prefix "pubky-grant-credential-v1"

  @type t :: %__MODULE__{
          grant_jws: String.t(),
          client_secret: Ed25519.secret(),
          homeserver: PublicKey.z32()
        }
  @derive {Inspect, only: [:homeserver]}
  @enforce_keys [:grant_jws, :client_secret, :homeserver]
  defstruct [:grant_jws, :client_secret, :homeserver]

  @doc "Serializes as `pubky-grant-credential-v1:<homeserver>:<base64url secret>:<grant jws>`."
  @spec export(t()) :: String.t()
  def export(%__MODULE__{} = c),
    do: Enum.join([@prefix, c.homeserver, B64.encode(c.client_secret), c.grant_jws], ":")

  @doc "Parses an exported credential."
  @spec import(String.t()) :: {:ok, t()} | {:error, :format | :version | :homeserver | :secret}
  def import(str) when is_binary(str) do
    case String.split(str, ":", parts: 4) do
      [@prefix, hs, secret, jws] ->
        with {:ok, hs} <- homeserver(hs), {:ok, secret} <- secret(secret) do
          {:ok, %__MODULE__{grant_jws: jws, client_secret: secret, homeserver: hs}}
        end

      [_other, _, _, _] ->
        {:error, :version}

      _ ->
        {:error, :format}
    end
  end

  def import(_), do: {:error, :format}

  @doc "Mints a fresh session from a credential (checks the grant is unexpired and matches the key)."
  @spec restore(t(), Config.t()) ::
          {:ok, Session.t()} | {:error, :expired | :cnf_mismatch | term()}
  def restore(%__MODULE__{} = c, %Config{} = config \\ Config.get()) do
    client = Keypair.from_secret(c.client_secret)

    with {:ok, grant} <- Grant.decode(c.grant_jws),
         true <- not Grant.expired?(grant) || {:error, :expired},
         true <- Keypair.public_z32(client) == grant.cnf || {:error, :cnf_mismatch} do
      Exchange.session(c.homeserver, grant, client, config)
    else
      {:error, _} = err -> err
    end
  end

  defp homeserver(str) do
    case PublicKey.parse(str) do
      {:ok, z32} -> {:ok, z32}
      :error -> {:error, :homeserver}
    end
  end

  defp secret(str) do
    case B64.decode(str) do
      {:ok, <<_::256>> = secret} -> {:ok, secret}
      _ -> {:error, :secret}
    end
  end
end

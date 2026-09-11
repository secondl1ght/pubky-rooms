defmodule Pubky.Auth.Grant do
  @moduledoc """
  A grant: a JWS signed by the **user's** key that authorizes a client key
  (`cnf`) to act on the user's homeserver with the listed capabilities.

  Claims (in wire order): `iss` (user pubky), `client_id`, `caps`, `cnf`
  (client public key), `jti` (grant id), `iat`, `exp` (Unix seconds).
  Pubky Ring signs grants for third-party apps; `sign/2` exists for local
  signers (tests, seeding, server-held identities).
  """

  alias Pubky.Auth.{Capability, Jws}
  alias Pubky.Crypto.B64
  alias Pubky.{Keypair, PublicKey}

  @typ "pubky-grant"
  @default_lifetime 2 * 365 * 24 * 3600

  @type t :: %__MODULE__{
          iss: PublicKey.z32(),
          client_id: String.t(),
          caps: [Capability.t()],
          cnf: PublicKey.z32(),
          jti: String.t(),
          iat: non_neg_integer(),
          exp: non_neg_integer(),
          jws: String.t()
        }

  @enforce_keys [:iss, :client_id, :caps, :cnf, :jti, :iat, :exp, :jws]
  defstruct [:iss, :client_id, :caps, :cnf, :jti, :iat, :exp, :jws]

  @doc "The JWS `typ` for grants."
  def typ, do: @typ

  @doc """
  Decodes a grant JWS. The signature is verified only when `verify: true`
  (the homeserver verifies it anyway; clients usually just inspect the claims).
  """
  @spec decode(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def decode(jws, opts \\ []) do
    with {:ok, %{header: %{"typ" => @typ}, claims: claims}} <- typed(Jws.decode(jws)),
         {:ok, iss} <- key(claims, "iss"),
         {:ok, cnf} <- key(claims, "cnf"),
         {:ok, caps} <- caps(claims["caps"]),
         %{"client_id" => client_id, "jti" => jti, "iat" => iat, "exp" => exp}
         when is_binary(client_id) and is_binary(jti) and is_integer(iat) and is_integer(exp) <-
           claims,
         :ok <- maybe_verify(opts[:verify], jws, iss) do
      {:ok,
       %__MODULE__{
         iss: iss,
         client_id: client_id,
         caps: caps,
         cnf: cnf,
         jti: jti,
         iat: iat,
         exp: exp,
         jws: jws
       }}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_grant}
    end
  end

  @doc "Signs a grant with the user's keypair (local signer)."
  @spec sign(Keypair.t(), keyword()) :: t()
  def sign(%Keypair{} = user, opts) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    caps = Keyword.fetch!(opts, :caps)
    client_id = Keyword.fetch!(opts, :client_id)
    cnf = Keyword.fetch!(opts, :cnf)
    jti = Keyword.get(opts, :jti, B64.random_id())
    exp = now + Keyword.get(opts, :lifetime, @default_lifetime)
    iss = Keypair.public_z32(user)

    claims = [
      {"iss", iss},
      {"client_id", client_id},
      {"caps", Enum.map(caps, &Capability.format/1)},
      {"cnf", cnf},
      {"jti", jti},
      {"iat", now},
      {"exp", exp}
    ]

    %__MODULE__{
      iss: iss,
      client_id: client_id,
      caps: caps,
      cnf: cnf,
      jti: jti,
      iat: now,
      exp: exp,
      jws: Jws.sign(user, @typ, claims)
    }
  end

  @doc "True when the grant has expired at `now`."
  @spec expired?(t(), non_neg_integer()) :: boolean()
  def expired?(%__MODULE__{exp: exp}, now \\ System.os_time(:second)), do: exp <= now

  defp typed({:ok, %{header: %{"typ" => @typ}}} = ok), do: ok
  defp typed({:ok, _}), do: {:error, :wrong_typ}
  defp typed(err), do: err

  defp key(claims, name) do
    case PublicKey.parse(Map.get(claims, name, "")) do
      {:ok, z32} -> {:ok, z32}
      :error -> {:error, {:invalid_claim, name}}
    end
  end

  defp caps(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case is_binary(item) && Capability.parse(item) do
        {:ok, cap} -> {:cont, {:ok, acc ++ [cap]}}
        _ -> {:halt, {:error, {:invalid_claim, "caps"}}}
      end
    end)
  end

  defp caps(_), do: {:error, {:invalid_claim, "caps"}}

  defp maybe_verify(true, jws, iss) do
    with {:ok, pk} <- PublicKey.to_bytes(iss),
         true <- Jws.verify(jws, pk),
         do: :ok,
         else: (_ -> {:error, :bad_signature})
  end

  defp maybe_verify(_, _jws, _iss), do: :ok
end

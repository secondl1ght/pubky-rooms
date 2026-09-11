defmodule Pubky.Keypair do
  @moduledoc """
  An Ed25519 keypair: a 32-byte secret seed and its public key.

  Keypairs are used for user identities (in tests and local signers) and for
  the per-app proof-of-possession key that grant auth binds a session to.
  The secret is redacted from `inspect/1`.
  """

  alias Pubky.Crypto.Ed25519
  alias Pubky.PublicKey

  @type t :: %__MODULE__{secret: Ed25519.secret(), public: Ed25519.public()}

  @derive {Inspect, only: [:public]}
  @enforce_keys [:secret, :public]
  defstruct [:secret, :public]

  @doc "Generates a random keypair."
  @spec generate() :: t()
  def generate do
    {public, secret} = Ed25519.generate()
    %__MODULE__{secret: secret, public: public}
  end

  @doc "Rebuilds a keypair from its 32-byte secret seed."
  @spec from_secret(Ed25519.secret()) :: t()
  def from_secret(<<_::256>> = secret) do
    %__MODULE__{secret: secret, public: Ed25519.public_from_secret(secret)}
  end

  @doc "The public key as a bare z-base-32 pubky."
  @spec public_z32(t()) :: PublicKey.z32()
  def public_z32(%__MODULE__{public: public}), do: PublicKey.from_bytes(public)

  @doc "Signs a message; returns the 64-byte signature."
  @spec sign(t(), iodata()) :: Ed25519.signature()
  def sign(%__MODULE__{secret: secret}, message), do: Ed25519.sign(secret, message)
end

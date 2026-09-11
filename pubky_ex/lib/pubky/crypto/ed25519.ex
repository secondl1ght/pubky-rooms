defmodule Pubky.Crypto.Ed25519 do
  @moduledoc """
  Ed25519 signatures over OTP's `:crypto` (no NIFs beyond what OTP ships).

  A *secret* here is the 32-byte seed, which is what Pubky Ring exports and
  what the Rust SDK calls `secret_key`. Public keys are 32 bytes, signatures 64.
  """

  @type secret :: <<_::256>>
  @type public :: <<_::256>>
  @type signature :: <<_::512>>

  @doc "Generates a fresh keypair as `{public, secret}`."
  @spec generate() :: {public(), secret()}
  def generate do
    {pub, secret} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, secret}
  end

  @doc "Derives the public key from a 32-byte secret seed."
  @spec public_from_secret(secret()) :: public()
  def public_from_secret(<<_::256>> = secret) do
    {pub, ^secret} = :crypto.generate_key(:eddsa, :ed25519, secret)
    pub
  end

  @doc "Signs `message` with the secret seed; returns the 64-byte signature."
  @spec sign(secret(), iodata()) :: signature()
  def sign(<<_::256>> = secret, message) do
    :crypto.sign(:eddsa, :none, message, [secret, :ed25519])
  end

  @doc "Verifies `signature` over `message` for `public`."
  @spec verify(public(), iodata(), binary()) :: boolean()
  def verify(<<_::256>> = public, message, <<_::512>> = signature) do
    :crypto.verify(:eddsa, :none, message, signature, [public, :ed25519])
  end

  def verify(_public, _message, _signature), do: false
end

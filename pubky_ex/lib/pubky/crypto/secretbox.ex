defmodule Pubky.Crypto.Secretbox do
  @moduledoc """
  XSalsa20-Poly1305 authenticated encryption (NaCl `secretbox`), in the layout
  the Pubky SDK and Pubky Ring use for relay messages:

      nonce (24 bytes) || Poly1305 tag (16 bytes) || ciphertext

  The tag-then-ciphertext body is libsodium's `crypto_secretbox_easy` layout,
  which is what `Kcl.secretbox/3` produces. Backed by the pure-Elixir `kcl` library.
  """

  @nonce_len 24

  @doc "Encrypts `plaintext` with a 32-byte key under a fresh random nonce."
  @spec encrypt(binary(), <<_::256>>) :: binary()
  def encrypt(plaintext, <<_::256>> = key) when is_binary(plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_len)
    nonce <> Kcl.secretbox(plaintext, nonce, key)
  end

  @doc "Decrypts a `nonce || box` message; `:error` on tampering or a wrong key."
  @spec decrypt(binary(), <<_::256>>) :: {:ok, binary()} | :error
  def decrypt(<<nonce::binary-size(@nonce_len), box::binary>>, <<_::256>> = key)
      when byte_size(box) >= 16 do
    case Kcl.secretunbox(box, nonce, key) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> :error
    end
  end

  def decrypt(_message, _key), do: :error
end

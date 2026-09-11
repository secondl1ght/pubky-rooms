defmodule Pubky.Crypto.B64 do
  @moduledoc "URL-safe base64 without padding, as used in JWS, deep links and relay ids."

  @doc "Encodes as base64url without padding."
  @spec encode(binary()) :: String.t()
  def encode(bin), do: Base.url_encode64(bin, padding: false)

  @doc "Decodes base64url, accepting both padded and unpadded input."
  @spec decode(String.t()) :: {:ok, binary()} | :error
  def decode(str) when is_binary(str),
    do: Base.url_decode64(String.trim_trailing(str, "="), padding: false)

  @doc "A 22-character random id (16 random bytes), the format used for grant ids and PoP nonces."
  @spec random_id() :: String.t()
  def random_id, do: encode(:crypto.strong_rand_bytes(16))
end

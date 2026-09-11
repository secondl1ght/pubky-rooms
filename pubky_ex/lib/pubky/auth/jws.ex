defmodule Pubky.Auth.Jws do
  @moduledoc """
  JWS Compact Serialization with Ed25519 (`EdDSA`, RFC 7515 + RFC 8037), as used
  for Pubky grants (`typ: "pubky-grant"`) and proof-of-possession proofs
  (`typ: "pubky-pop"`).

  The header is emitted as the exact literal `{"alg":"EdDSA","typ":<typ>}` and
  claims are encoded in the order given, so the bytes are reproducible and
  match the Rust implementation byte for byte. The signature covers the ASCII
  string `base64url(header) <> "." <> base64url(payload)`.
  """

  alias Pubky.Crypto.{B64, Ed25519}
  alias Pubky.Keypair

  @type decoded :: %{header: map(), claims: map(), signature: binary(), signing_input: String.t()}

  @doc "Signs ordered claims (`[{key, value}]`) as a compact JWS."
  @spec sign(Keypair.t(), String.t(), [{String.t(), term()}]) :: String.t()
  def sign(%Keypair{} = keypair, typ, claims) do
    input = signing_input(typ, claims)
    finish(input, Keypair.sign(keypair, input))
  end

  @doc "The `base64url(header).base64url(payload)` string that gets signed."
  @spec signing_input(String.t(), [{String.t(), term()}]) :: String.t()
  def signing_input(typ, claims) do
    header = ~s({"alg":"EdDSA","typ":#{JSON.encode!(typ)}})
    B64.encode(header) <> "." <> B64.encode(encode_ordered(claims))
  end

  @doc "Appends a raw 64-byte signature to a signing input."
  @spec finish(String.t(), binary()) :: String.t()
  def finish(signing_input, signature), do: signing_input <> "." <> B64.encode(signature)

  @doc "Decodes a compact JWS without verifying it."
  @spec decode(String.t()) :: {:ok, decoded()} | {:error, :format | :base64 | :json}
  def decode(compact) when is_binary(compact) do
    with [h, p, s] <- String.split(compact, "."),
         {:ok, header_json} <- B64.decode(h),
         {:ok, payload_json} <- B64.decode(p),
         {:ok, signature} <- B64.decode(s),
         {:ok, header} when is_map(header) <- json(header_json),
         {:ok, claims} when is_map(claims) <- json(payload_json) do
      {:ok, %{header: header, claims: claims, signature: signature, signing_input: h <> "." <> p}}
    else
      :error -> {:error, :base64}
      {:error, :json} -> {:error, :json}
      _ -> {:error, :format}
    end
  end

  def decode(_), do: {:error, :format}

  @doc "Verifies a compact JWS against a 32-byte Ed25519 public key."
  @spec verify(String.t(), Ed25519.public()) :: boolean()
  def verify(compact, public) do
    case decode(compact) do
      {:ok, %{header: %{"alg" => "EdDSA"}, signature: sig, signing_input: input}} ->
        Ed25519.verify(public, input, sig)

      _ ->
        false
    end
  end

  defp json(bin) do
    case JSON.decode(bin) do
      {:ok, v} -> {:ok, v}
      _ -> {:error, :json}
    end
  end

  # JSON object with the given key order (Elixir maps do not preserve order).
  defp encode_ordered(pairs) do
    "{" <>
      Enum.map_join(pairs, ",", fn {k, v} ->
        JSON.encode!(to_string(k)) <> ":" <> JSON.encode!(v)
      end) <> "}"
  end
end

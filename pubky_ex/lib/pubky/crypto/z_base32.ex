defmodule Pubky.Crypto.ZBase32 do
  @moduledoc """
  z-base-32 encoding (Zooko's human-oriented base32), used for Pubky public keys.

  Alphabet: `ybndrfg8ejkmcpqxot1uwisza345h769`. Bits are consumed most
  significant first in 5-bit groups; there is no padding. A 32-byte key encodes
  to 52 characters, the last of which carries only one data bit.
  """

  import Bitwise

  @alphabet ~c"ybndrfg8ejkmcpqxot1uwisza345h769"
  @encode_map @alphabet |> Enum.with_index() |> Map.new(fn {c, i} -> {i, c} end)
  @decode_map @alphabet |> Enum.with_index() |> Map.new(fn {c, i} -> {c, i} end)

  @doc "Encodes a binary."
  @spec encode(binary()) :: String.t()
  def encode(bin) when is_binary(bin) do
    bin
    |> chunks_of_5()
    |> Enum.map(&Map.fetch!(@encode_map, &1))
    |> List.to_string()
  end

  @doc """
  Decodes a z-base-32 string. Any non-alphabet character yields `:error`, and
  so do non-zero trailing padding bits: every byte string has exactly one
  encoding, so two different strings can never name the same key.
  """
  @spec decode(String.t()) :: {:ok, binary()} | :error
  def decode(str) when is_binary(str) do
    str
    |> String.to_charlist()
    |> Enum.reduce_while({<<>>, 0, 0}, fn c, {acc, buf, nbits} ->
      case Map.fetch(@decode_map, c) do
        {:ok, v} -> {:cont, push_bits(acc, buf <<< 5 ||| v, nbits + 5)}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      {acc, 0, _nbits} -> {:ok, acc}
      {_acc, _padding, _nbits} -> :error
    end
  end

  defp push_bits(acc, buf, nbits) when nbits >= 8 do
    nbits = nbits - 8
    byte = buf >>> nbits &&& 0xFF
    {<<acc::binary, byte>>, buf &&& (1 <<< nbits) - 1, nbits}
  end

  defp push_bits(acc, buf, nbits), do: {acc, buf, nbits}

  defp chunks_of_5(bin) do
    bits = bit_size(bin)
    pad = rem(5 - rem(bits, 5), 5)
    padded = <<bin::bitstring, 0::size(pad)>>
    for <<chunk::5 <- padded>>, do: chunk
  end
end

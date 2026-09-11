defmodule Pubky.PublicKey do
  @moduledoc """
  Pubky public keys ("pubkys"): 32-byte Ed25519 keys rendered as 52-character z-base-32.

  Functions accept the bare 52 characters or the `pubky`-prefixed display form
  (`pubkyihaqcth…`), and always return the bare form.
  """

  alias Pubky.Crypto.ZBase32

  @type z32 :: String.t()

  @z32_regex ~r/^[ybndrfg8ejkmcpqxot1uwisza345h769]{52}$/

  @doc "Parses and normalizes a pubky; returns the bare 52-char z-base-32 string."
  @spec parse(String.t()) :: {:ok, z32()} | :error
  def parse("pubky" <> rest) when byte_size(rest) == 52, do: parse(rest)

  def parse(str) when is_binary(str) do
    if Regex.match?(@z32_regex, str) do
      case ZBase32.decode(str) do
        {:ok, <<_::256>>} -> {:ok, str}
        _ -> :error
      end
    else
      :error
    end
  end

  def parse(_), do: :error

  @doc "Same as `parse/1` but raises on invalid input."
  @spec parse!(String.t()) :: z32()
  def parse!(str) do
    case parse(str) do
      {:ok, z32} -> z32
      :error -> raise ArgumentError, "invalid pubky: #{inspect(str)}"
    end
  end

  @doc "True when the string is a valid bare or prefixed pubky."
  @spec valid?(term()) :: boolean()
  def valid?(str), do: match?({:ok, _}, parse(str))

  @doc "Decodes a pubky to its 32 raw bytes."
  @spec to_bytes(z32()) :: {:ok, <<_::256>>} | :error
  def to_bytes(str) do
    with {:ok, z32} <- parse(str), {:ok, <<_::256>> = bytes} <- ZBase32.decode(z32), do: {:ok, bytes}
  end

  @doc "Encodes 32 raw bytes as a bare pubky."
  @spec from_bytes(<<_::256>>) :: z32()
  def from_bytes(<<_::256>> = bytes), do: ZBase32.encode(bytes)
end

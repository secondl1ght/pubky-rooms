defmodule PubkyRooms.Ids do
  @moduledoc """
  Identifiers used on homeservers.

  Room and message ids are *timestamp ids* as defined by pubky-app-specs:
  the microsecond Unix timestamp as an 8-byte big-endian integer, encoded in
  Crockford base32 (13 characters). Lexical order equals chronological order,
  which makes directory listings chronological for free.

  `next/0` is monotonic per node: two calls in the same microsecond (or after a
  clock step backwards) still yield strictly increasing ids.
  """

  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @id_re ~r/^[0-9A-HJKMNP-TV-Z]{13}$/
  @z32_re ~r/^[ybndrfg8ejkmcpqxot1uwisza345h769]{52}$/

  @type id :: <<_::104>>

  @doc "Creates the monotonic clock (called once from the application supervisor)."
  @spec init() :: :ok
  def init do
    ref = :atomics.new(1, signed: true)
    :persistent_term.put({__MODULE__, :clock}, ref)
    :ok
  end

  @doc "Returns a fresh, strictly increasing timestamp id."
  @spec next() :: id()
  def next do
    ref = :persistent_term.get({__MODULE__, :clock})
    encode(bump(ref, System.os_time(:microsecond)))
  end

  defp bump(ref, now) do
    last = :atomics.get(ref, 1)
    candidate = max(now, last + 1)

    case :atomics.compare_exchange(ref, 1, last, candidate) do
      :ok -> candidate
      _ -> bump(ref, now)
    end
  end

  @doc "Encodes a microsecond timestamp as a 13-character Crockford base32 id."
  @spec encode(non_neg_integer()) :: id()
  def encode(micros) when is_integer(micros) and micros >= 0 do
    padded = <<micros::64, 0::1>>
    for <<chunk::5 <- padded>>, into: "", do: <<Enum.at(@alphabet, chunk)>>
  end

  @doc "Decodes a timestamp id back to microseconds."
  @spec decode(String.t()) :: {:ok, non_neg_integer()} | :error
  def decode(id) when is_binary(id) do
    if valid_id?(id) do
      bits =
        for <<c <- id>>, into: <<>> do
          <<Enum.find_index(@alphabet, &(&1 == c))::5>>
        end

      <<micros::64, _::1>> = bits
      {:ok, micros}
    else
      :error
    end
  end

  def decode(_), do: :error

  @doc "Whether the string is a well-formed timestamp id."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_re, id)
  def valid_id?(_), do: false

  @doc "Whether the string is a well-formed z-base32 public key (52 chars)."
  @spec valid_z32?(term()) :: boolean()
  def valid_z32?(z32) when is_binary(z32), do: Regex.match?(@z32_re, z32)
  def valid_z32?(_), do: false
end

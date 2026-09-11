defmodule Pubky.Crypto.Blake3 do
  @moduledoc """
  Pure-Elixir BLAKE3 (unkeyed hash mode), following the reference implementation.

  Pubky uses BLAKE3 for HTTP relay channel ids (`blake3(client_secret)`),
  homeserver content hashes (`ETag` and SSE `content_hash`), and pubky.app
  hash ids. Inputs are small, so a straightforward implementation on the BEAM
  is fast enough; OTP's `:crypto` does not ship BLAKE3.
  """

  import Bitwise

  @iv {0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB,
       0x5BE0CD19}
  @permutation {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8}

  @block_len 64
  @chunk_len 1024
  @chunk_start 1
  @chunk_end 2
  @parent 4
  @root 8
  @mask 0xFFFFFFFF

  @doc "Hashes `data`, returning `out_len` bytes (default 32)."
  @spec hash(iodata(), pos_integer()) :: binary()
  def hash(data, out_len \\ 32) when out_len > 0 do
    input = IO.iodata_to_binary(data)
    output = hash_subtree(input, 0)
    root_output_bytes(output, out_len)
  end

  @doc "Hex-encoded lower-case hash."
  @spec hex(iodata(), pos_integer()) :: String.t()
  def hex(data, out_len \\ 32), do: data |> hash(out_len) |> Base.encode16(case: :lower)

  # An "output" is a pending final compression: {input_cv, block_words, counter, block_len, flags}.

  defp hash_subtree(input, chunk_counter) when byte_size(input) <= @chunk_len do
    chunk_output(input, chunk_counter)
  end

  defp hash_subtree(input, chunk_counter) do
    left_len = left_len(byte_size(input))
    <<left::binary-size(left_len), right::binary>> = input
    left_cv = chaining_value(hash_subtree(left, chunk_counter))
    right_cv = chaining_value(hash_subtree(right, chunk_counter + div(left_len, @chunk_len)))

    {@iv, List.to_tuple(Tuple.to_list(left_cv) ++ Tuple.to_list(right_cv)), 0, @block_len,
     @parent}
  end

  # The left subtree gets the largest power-of-two number of full chunks that
  # still leaves at least one byte for the right subtree.
  defp left_len(content_len) do
    full_chunks = div(content_len - 1, @chunk_len)
    round_down_pow2(full_chunks) * @chunk_len
  end

  defp round_down_pow2(n) when n >= 1, do: 1 <<< (bit_length(n) - 1)

  defp bit_length(0), do: 0
  defp bit_length(n), do: 1 + bit_length(n >>> 1)

  defp chunk_output(chunk, chunk_counter) do
    blocks = blocks(chunk)
    {last, init} = List.pop_at(blocks, -1)

    {cv, first?} =
      Enum.reduce(init, {@iv, true}, fn block, {cv, first?} ->
        flags = if first?, do: @chunk_start, else: 0
        {first8(compress(cv, words(block), chunk_counter, @block_len, flags)), false}
      end)

    flags = if(first?, do: @chunk_start, else: 0) ||| @chunk_end
    {cv, words(pad(last)), chunk_counter, byte_size(last), flags}
  end

  # Splits a chunk into 64-byte blocks; the last block may be short (or empty for empty input).
  defp blocks(<<>>), do: [<<>>]
  defp blocks(chunk), do: blocks(chunk, [])

  defp blocks(<<block::binary-size(@block_len), rest::binary>>, acc) when rest != <<>>,
    do: blocks(rest, [block | acc])

  defp blocks(last, acc), do: Enum.reverse([last | acc])

  defp pad(block) when byte_size(block) == @block_len, do: block
  defp pad(block), do: block <> :binary.copy(<<0>>, @block_len - byte_size(block))

  defp words(<<block::binary-size(@block_len)>>) do
    for(<<w::little-32 <- block>>, do: w) |> List.to_tuple()
  end

  defp chaining_value({cv, block_words, counter, block_len, flags}),
    do: first8(compress(cv, block_words, counter, block_len, flags))

  defp root_output_bytes({cv, block_words, _counter, block_len, flags}, out_len) do
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(fn counter ->
      compress(cv, block_words, counter, block_len, flags ||| @root) |> words_to_binary()
    end)
    |> Enum.reduce_while(<<>>, fn chunk, acc ->
      acc = acc <> chunk
      if byte_size(acc) >= out_len, do: {:halt, binary_part(acc, 0, out_len)}, else: {:cont, acc}
    end)
  end

  defp first8(state), do: Tuple.to_list(state) |> Enum.take(8) |> List.to_tuple()

  defp words_to_binary(state) do
    state |> Tuple.to_list() |> Enum.map(&<<&1::little-32>>) |> IO.iodata_to_binary()
  end

  # ── Compression function ───────────────────────────────────────────────────

  @doc false
  def compress({c0, c1, c2, c3, c4, c5, c6, c7} = cv, m, counter, block_len, flags) do
    {i0, i1, i2, i3, _, _, _, _} = @iv

    state =
      {c0, c1, c2, c3, c4, c5, c6, c7, i0, i1, i2, i3, counter &&& @mask,
       counter >>> 32 &&& @mask, block_len, flags}

    {state, _m} =
      Enum.reduce(1..7, {state, m}, fn round_no, {s, m} ->
        s = round(s, m)
        {s, if(round_no < 7, do: permute(m), else: m)}
      end)

    finalize(state, cv)
  end

  defp finalize(s, cv) do
    s = Enum.reduce(0..7, s, fn i, s -> put_elem(s, i, bxor(elem(s, i), elem(s, i + 8))) end)
    Enum.reduce(0..7, s, fn i, s -> put_elem(s, i + 8, bxor(elem(s, i + 8), elem(cv, i))) end)
  end

  defp round(s, m) do
    s
    |> g(0, 4, 8, 12, elem(m, 0), elem(m, 1))
    |> g(1, 5, 9, 13, elem(m, 2), elem(m, 3))
    |> g(2, 6, 10, 14, elem(m, 4), elem(m, 5))
    |> g(3, 7, 11, 15, elem(m, 6), elem(m, 7))
    |> g(0, 5, 10, 15, elem(m, 8), elem(m, 9))
    |> g(1, 6, 11, 12, elem(m, 10), elem(m, 11))
    |> g(2, 7, 8, 13, elem(m, 12), elem(m, 13))
    |> g(3, 4, 9, 14, elem(m, 14), elem(m, 15))
  end

  defp g(s, ia, ib, ic, id, mx, my) do
    a = elem(s, ia)
    b = elem(s, ib)
    c = elem(s, ic)
    d = elem(s, id)

    a = a + b + mx &&& @mask
    d = rotr(bxor(d, a), 16)
    c = c + d &&& @mask
    b = rotr(bxor(b, c), 12)
    a = a + b + my &&& @mask
    d = rotr(bxor(d, a), 8)
    c = c + d &&& @mask
    b = rotr(bxor(b, c), 7)

    s |> put_elem(ia, a) |> put_elem(ib, b) |> put_elem(ic, c) |> put_elem(id, d)
  end

  defp rotr(x, n), do: (x >>> n ||| x <<< (32 - n)) &&& @mask

  defp permute(m) do
    List.to_tuple(for i <- 0..15, do: elem(m, elem(@permutation, i)))
  end
end

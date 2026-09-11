defmodule Pubky.Crypto.Blake3Test do
  use ExUnit.Case, async: true

  alias Pubky.Crypto.Blake3

  @vectors "test/fixtures/blake3_test_vectors.json" |> File.read!() |> JSON.decode!()

  # The official vectors hash an input made of the bytes 0, 1, …, 250 repeating.
  defp input(len), do: Stream.cycle(0..250) |> Enum.take(len) |> :binary.list_to_bin()

  test "empty input" do
    assert Blake3.hex("") == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
  end

  test "official test vectors (32-byte digests) for every case" do
    for %{"input_len" => len, "hash" => expected} <- @vectors["cases"] do
      assert Blake3.hex(input(len)) == String.slice(expected, 0, 64), "input_len=#{len}"
    end
  end

  test "extended output matches the full 131-byte vectors" do
    for %{"input_len" => len, "hash" => expected} <- Enum.take(@vectors["cases"], 14) do
      assert Blake3.hex(input(len), div(String.length(expected), 2)) == expected,
             "input_len=#{len}"
    end
  end

  test "accepts iodata" do
    assert Blake3.hash(["he", "llo"]) == Blake3.hash("hello")
  end
end

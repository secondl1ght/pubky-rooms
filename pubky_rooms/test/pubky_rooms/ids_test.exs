defmodule PubkyRooms.IdsTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Ids

  test "encodes timestamps as 13-char Crockford base32, big-endian bit packing" do
    assert Ids.encode(0) == "0000000000000"
    # 2024-01-01T00:00:00Z in µs
    id = Ids.encode(1_704_067_200_000_000)
    assert String.length(id) == 13
    assert Ids.valid_id?(id)
    assert Ids.decode(id) == {:ok, 1_704_067_200_000_000}
  end

  test "lexical order equals chronological order" do
    ids =
      for t <- [1, 31, 32, 1_000_000, 1_704_067_200_000_000, 1_704_067_200_000_001],
          do: Ids.encode(t)

    assert ids == Enum.sort(ids)
  end

  test "next/0 is strictly increasing" do
    ids = for _ <- 1..500, do: Ids.next()
    assert ids == Enum.uniq(ids)
    assert ids == Enum.sort(ids)
  end

  test "validation" do
    assert Ids.valid_id?("0000000000000")
    refute Ids.valid_id?("000000000000I")
    refute Ids.valid_id?("00000000000000")
    assert Ids.valid_z32?(String.duplicate("y", 52))
    refute Ids.valid_z32?(String.duplicate("y", 51))
    refute Ids.valid_z32?(String.duplicate("l", 52))
    assert Ids.decode("bad") == :error
  end
end

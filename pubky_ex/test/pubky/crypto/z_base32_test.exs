defmodule Pubky.Crypto.ZBase32Test do
  use ExUnit.Case, async: true

  alias Pubky.Crypto.ZBase32

  test "reference vectors" do
    assert ZBase32.encode("hello") == "pb1sa5dx"
    assert ZBase32.encode(<<0xFF>>) == "9h"
    assert ZBase32.encode(<<0>>) == "yy"
    assert ZBase32.encode(<<>>) == ""
  end

  test "known pubkys round-trip to their hex keys" do
    for {z32, hex} <- [
          {"ihaqcthsdbk751sxctk849bdr7yz7a934qen5gmpcbwcur49i97y",
           "af30e647961855ddcacf64547d7c2327417ee3f9d3902d996d6068c9935faffa"},
          {"8um71us3fyw6h8wbcxb5ar3rwusy1a6u49956ikzojg3gcwd1dty",
           "3cd7d94ed92829ee1e8163c3bc1324a4ec0963d3d7ffbf5557824d93328390e2"}
        ] do
      bytes = Base.decode16!(hex, case: :lower)
      assert ZBase32.encode(bytes) == z32
      assert ZBase32.decode(z32) == {:ok, bytes}
    end
  end

  test "32 random bytes encode to 52 chars and round-trip" do
    for _ <- 1..50 do
      bytes = :crypto.strong_rand_bytes(32)
      encoded = ZBase32.encode(bytes)
      assert String.length(encoded) == 52
      assert ZBase32.decode(encoded) == {:ok, bytes}
    end
  end

  test "rejects characters outside the alphabet" do
    assert ZBase32.decode("pb1sa5dl") == :error
    assert ZBase32.decode("PB1SA5DX") == :error
  end
end

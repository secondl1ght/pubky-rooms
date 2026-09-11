defmodule Pubky.PublicKeyTest do
  use ExUnit.Case, async: true

  alias Pubky.{Keypair, PublicKey}

  @z32 "ihaqcthsdbk751sxctk849bdr7yz7a934qen5gmpcbwcur49i97y"

  test "parses bare and prefixed forms" do
    assert PublicKey.parse(@z32) == {:ok, @z32}
    assert PublicKey.parse("pubky" <> @z32) == {:ok, @z32}
    assert PublicKey.parse!(@z32) == @z32
    assert PublicKey.valid?(@z32)
  end

  test "rejects bad input" do
    assert PublicKey.parse("") == :error
    assert PublicKey.parse(String.slice(@z32, 0, 51)) == :error
    assert PublicKey.parse(String.upcase(@z32)) == :error
    assert PublicKey.parse(nil) == :error
    refute PublicKey.valid?("not-a-key")
    assert_raise ArgumentError, fn -> PublicKey.parse!("nope") end
  end

  test "bytes round trip through keypairs" do
    kp = Keypair.generate()
    z32 = Keypair.public_z32(kp)
    assert PublicKey.to_bytes(z32) == {:ok, kp.public}
    assert PublicKey.from_bytes(kp.public) == z32
    assert Keypair.from_secret(kp.secret).public == kp.public
    refute inspect(kp) =~ Base.encode16(kp.secret)
  end
end

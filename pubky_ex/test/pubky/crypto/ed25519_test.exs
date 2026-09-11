defmodule Pubky.Crypto.Ed25519Test do
  use ExUnit.Case, async: true

  alias Pubky.Crypto.Ed25519

  # RFC 8032 §7.1, TEST 1
  @seed Base.decode16!("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
          case: :lower
        )
  @pub Base.decode16!("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
         case: :lower
       )
  @sig Base.decode16!(
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
         case: :lower
       )

  test "RFC 8032 vector" do
    assert Ed25519.public_from_secret(@seed) == @pub
    assert Ed25519.sign(@seed, "") == @sig
    assert Ed25519.verify(@pub, "", @sig)
    refute Ed25519.verify(@pub, "x", @sig)
  end

  test "generate/sign/verify round trip" do
    {pub, secret} = Ed25519.generate()
    sig = Ed25519.sign(secret, "hello")
    assert byte_size(sig) == 64
    assert Ed25519.verify(pub, "hello", sig)
    refute Ed25519.verify(pub, "hello", <<0::512>>)
    refute Ed25519.verify(pub, "hello", <<1, 2, 3>>)
  end
end

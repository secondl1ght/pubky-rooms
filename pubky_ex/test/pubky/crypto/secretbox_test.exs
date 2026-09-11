defmodule Pubky.Crypto.SecretboxTest do
  use ExUnit.Case, async: true

  alias Pubky.Crypto.Secretbox

  @kat "test/fixtures/secretbox_libsodium.json" |> File.read!() |> JSON.decode!()

  defp hex(name), do: Base.decode16!(@kat[name], case: :lower)

  test "kcl produces libsodium's crypto_secretbox_easy layout (known-answer test)" do
    assert Kcl.secretbox(hex("message"), hex("nonce"), hex("key")) == hex("box")
    assert Secretbox.decrypt(hex("nonce") <> hex("box"), hex("key")) == {:ok, hex("message")}
  end

  test "encrypt/decrypt round trip with random nonces" do
    key = :crypto.strong_rand_bytes(32)
    msg = "eyJhbGciOiJFZERTQSIsInR5cCI6InB1Ymt5LWdyYW50In0.payload.sig"
    a = Secretbox.encrypt(msg, key)
    b = Secretbox.encrypt(msg, key)
    assert a != b
    assert byte_size(a) == 24 + 16 + byte_size(msg)
    assert Secretbox.decrypt(a, key) == {:ok, msg}
    assert Secretbox.decrypt(b, key) == {:ok, msg}
  end

  test "tampering, wrong keys and short input fail closed" do
    key = :crypto.strong_rand_bytes(32)
    other = :crypto.strong_rand_bytes(32)
    ct = Secretbox.encrypt("secret", key)
    <<head::binary-30, byte, rest::binary>> = ct
    assert Secretbox.decrypt(<<head::binary, Bitwise.bxor(byte, 1), rest::binary>>, key) == :error
    assert Secretbox.decrypt(ct, other) == :error
    assert Secretbox.decrypt(<<1, 2, 3>>, key) == :error
  end
end

defmodule Pubky.Pkarr.SignedPacketTest do
  use ExUnit.Case, async: true

  alias Pubky.Keypair
  alias Pubky.Pkarr.SignedPacket
  alias Pubky.Test.Fixtures

  test "verifies real relay payloads" do
    assert {:ok, sp} =
             SignedPacket.decode_relay_payload(Fixtures.user_z32(), Fixtures.user_payload())

    assert sp.timestamp_us == 1_788_680_981_480_831
    assert [%{rdata: {:https, %{target: target}}}] = SignedPacket.resource_records(sp, "_pubky")
    assert target == Fixtures.homeserver_z32()

    assert {:ok, hs} =
             SignedPacket.decode_relay_payload(
               Fixtures.homeserver_z32(),
               Fixtures.homeserver_payload()
             )

    assert hs.timestamp_us == 1_788_168_146_956_031
    assert length(SignedPacket.resource_records(hs, "@")) == 3
  end

  test "rejects tampered payloads and wrong keys" do
    payload = Fixtures.user_payload()
    <<head::binary-100, byte, rest::binary>> = payload
    tampered = <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>

    assert SignedPacket.decode_relay_payload(Fixtures.user_z32(), tampered) ==
             {:error, :bad_signature}

    assert SignedPacket.decode_relay_payload(Fixtures.homeserver_z32(), payload) ==
             {:error, :bad_signature}

    assert SignedPacket.decode_relay_payload(Fixtures.user_z32(), <<1, 2, 3>>) ==
             {:error, :too_short}

    assert SignedPacket.decode_relay_payload("nope", payload) == {:error, :bad_public_key}
  end

  test "build/3 signs a packet that decodes and verifies, and reproduces the fixture bytes" do
    kp = Keypair.generate()
    rr = SignedPacket.pubky_record(Keypair.public_z32(kp), Fixtures.homeserver_z32())
    {:ok, sp} = SignedPacket.build(kp, [rr], 1_700_000_000_000_000)

    assert {:ok, decoded} =
             SignedPacket.decode_relay_payload(
               Keypair.public_z32(kp),
               SignedPacket.encode_relay_payload(sp)
             )

    assert decoded.records == [rr]

    # the same record for the real user must produce the fixture's DNS bytes
    fixture_packet =
      binary_part(Fixtures.user_payload(), 72, byte_size(Fixtures.user_payload()) - 72)

    {:ok, rebuilt} =
      SignedPacket.build(kp, [
        SignedPacket.pubky_record(Fixtures.user_z32(), Fixtures.homeserver_z32())
      ])

    assert rebuilt.packet == fixture_packet
  end
end

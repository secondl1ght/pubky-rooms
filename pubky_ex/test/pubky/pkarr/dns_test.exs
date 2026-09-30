defmodule Pubky.Pkarr.DnsTest do
  use ExUnit.Case, async: true

  alias Pubky.Pkarr.Dns
  alias Pubky.Pkarr.Dns.{Packet, RR}
  alias Pubky.Test.Fixtures

  defp packet_of(payload), do: binary_part(payload, 72, byte_size(payload) - 72)

  test "decodes the user packet: one _pubky HTTPS record" do
    {:ok, %Packet{answers: [rr]} = p} = Dns.decode(packet_of(Fixtures.user_payload()))
    assert p.flags == 0x8000
    assert rr.name == "_pubky." <> Fixtures.user_z32()
    assert rr.type == 65
    assert rr.ttl == 3600
    assert rr.rdata == {:https, %{priority: 0, target: Fixtures.homeserver_z32(), params: %{}}}
  end

  test "decodes the homeserver packet with compression pointers and SvcParams" do
    {:ok, %Packet{answers: [direct, icann, a]}} =
      Dns.decode(packet_of(Fixtures.homeserver_payload()))

    hs = Fixtures.homeserver_z32()

    assert %RR{name: ^hs, type: 65, rdata: {:https, %{priority: 1, target: "", params: params}}} =
             direct

    assert Dns.svcparam_u16(params, Dns.svcparam_port()) == 6287
    assert Dns.ipv4hints(params) == [{34, 65, 156, 171}]

    assert %RR{
             name: ^hs,
             type: 65,
             rdata: {:https, %{priority: 10, target: "homeserver.pubky.app", params: %{}}}
           } = icann

    assert %RR{name: ^hs, type: 1, rdata: {:a, {34, 65, 156, 171}}} = a
  end

  test "encoder reproduces the user packet bytes exactly" do
    packet = packet_of(Fixtures.user_payload())
    {:ok, decoded} = Dns.decode(packet)
    assert Dns.encode(decoded) == packet
  end

  test "encodes and decodes every supported rdata type" do
    answers = [
      %RR{name: "example.test", type: 1, ttl: 60, rdata: {:a, {1, 2, 3, 4}}},
      %RR{
        name: "example.test",
        type: 28,
        ttl: 60,
        rdata: {:aaaa, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}}
      },
      %RR{name: "example.test", type: 16, ttl: 60, rdata: {:txt, ["hello", "world"]}},
      %RR{name: "alias.example.test", type: 5, ttl: 60, rdata: {:cname, "example.test"}},
      %RR{
        name: "example.test",
        type: 65,
        ttl: 60,
        rdata:
          {:https,
           %{
             priority: 10,
             target: "localhost",
             params: %{3 => <<443::16>>, 65_280 => <<6286::16>>}
           }}
      },
      %RR{name: "example.test", type: 99, ttl: 60, rdata: {:raw, <<1, 2, 3>>}}
    ]

    {:ok, %Packet{answers: decoded}} = Dns.decode(Dns.encode(%Packet{answers: answers}))
    assert decoded == answers
  end

  test "rejects truncated packets and pointer loops without raising" do
    assert Dns.decode(<<0, 0, 0>>) == {:error, :truncated_header}

    assert {:error, {:truncated, _}} =
             Dns.decode(<<0::16, 0x8000::16, 0::16, 1::16, 0::16, 0::16, 3, ?a>>)

    # a name that points at itself
    loop = <<0::16, 0x8000::16, 0::16, 1::16, 0::16, 0::16, 0xC0, 12>>
    assert Dns.decode(loop) == {:error, :pointer_loop}
  end

  test "an HTTPS record whose target name runs past its rdata does not raise" do
    # header (ancount 1), root name, type 65, class 1, ttl 0, rdlen 2, priority 10,
    # then a valid name that belongs to whatever follows the record
    packet =
      <<0::16, 0x8000::16, 0::16, 1::16, 0::16, 0::16, 0, 65::16, 1::16, 0::32, 2::16, 10::16, 1,
        ?a, 0>>

    assert {_ok_or_error, _} = Dns.decode(packet)
  end

  test "names are lower-cased and the root name is empty" do
    assert Dns.decode_name(<<3, ?F, ?o, ?O, 0>>, 0) == {:ok, "foo", 5}
    assert Dns.decode_name(<<0>>, 0) == {:ok, "", 1}
    assert Dns.encode_name("") == <<0>>
    assert Dns.encode_name("a.b.") == <<1, ?a, 1, ?b, 0>>
  end
end

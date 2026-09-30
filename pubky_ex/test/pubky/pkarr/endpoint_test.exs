defmodule Pubky.Pkarr.EndpointTest do
  use ExUnit.Case, async: true

  alias Pubky.{Config, Keypair}
  alias Pubky.Pkarr.Dns.RR
  alias Pubky.Pkarr.{Endpoint, SignedPacket}
  alias Pubky.Test.Fixtures

  test "mainnet homeserver resolves to its ICANN https endpoint" do
    {:ok, sp} =
      SignedPacket.decode_relay_payload(Fixtures.homeserver_z32(), Fixtures.homeserver_payload())

    endpoints = Endpoint.from_packet(sp)

    assert [
             %{priority: 1, target: "", port: 6287},
             %{priority: 10, target: "homeserver.pubky.app", port: nil}
           ] = endpoints

    assert Endpoint.icann_base_url(endpoints, Config.mainnet()) ==
             {:ok, "https://homeserver.pubky.app"}
  end

  test "testnet-style packet: localhost with the plain-http SvcParam" do
    kp = Keypair.generate()
    hs = Keypair.public_z32(kp)

    records = [
      %RR{
        name: hs,
        type: 65,
        ttl: 60,
        rdata: {:https, %{priority: 1, target: "", params: %{3 => <<6287::16>>}}}
      },
      %RR{
        name: hs,
        type: 65,
        ttl: 60,
        rdata: {:https, %{priority: 10, target: "localhost", params: %{65_280 => <<6286::16>>}}}
      }
    ]

    {:ok, sp} = SignedPacket.build(kp, records)

    assert Endpoint.icann_base_url(Endpoint.from_packet(sp), Config.testnet()) ==
             {:ok, "http://localhost:6286"}

    # on mainnet a packet cannot point the client at the node's own network
    assert Endpoint.icann_base_url(Endpoint.from_packet(sp), Config.mainnet()) ==
             {:error, :no_icann_endpoint}
  end

  test "mainnet accepts only public hostnames" do
    for host <- ["homeserver.pubky.app", "hs.example.org.", "203.0.113.9", "2001:db8::1"],
        do: assert(Endpoint.public_host?(host), host)

    for host <- [
          "127.1",
          "10.1",
          "0x7f.1",
          "0177.0.0.1",
          "localhost",
          "LOCALHOST",
          "db.localhost",
          "printer.local",
          "api.internal",
          "router.home.arpa",
          "intranet",
          "",
          "bad_host.example",
          "-x.example",
          "127.0.0.1",
          "10.0.0.5",
          "100.64.1.1",
          "169.254.169.254",
          "172.16.0.1",
          "192.168.1.1",
          "0.0.0.0",
          "224.0.0.1",
          "::1",
          "::",
          "::ffff:127.0.0.1",
          "fdaa::1",
          "fe80::1"
        ],
        do: refute(Endpoint.public_host?(host), host)

    assert Endpoint.allowed_target?("localhost", Config.mainnet(allow_private_hosts: true))
    refute Endpoint.allowed_target?("localhost", Config.mainnet())
  end

  test "a name is also judged by what it resolves to" do
    # a public-looking name whose address is loopback is refused by address
    refute Endpoint.resolves_public?("localhost")
    refute Endpoint.resolves_public?("127.0.0.1")
    refute Endpoint.vetted_host?("localhost", Config.mainnet())
    assert Endpoint.vetted_host?("localhost", Config.mainnet(allow_private_hosts: true))
    # a name that does not resolve at all is left to the connection to fail
    assert Endpoint.resolves_public?("no-such-host.invalid")
  end

  test "the plain-http SvcParam is ignored on mainnet" do
    kp = Keypair.generate()
    hs = Keypair.public_z32(kp)

    {:ok, sp} =
      SignedPacket.build(kp, [
        %RR{
          name: hs,
          type: 65,
          ttl: 60,
          rdata:
            {:https, %{priority: 10, target: "hs.example.org", params: %{65_280 => <<8080::16>>}}}
        }
      ])

    assert Endpoint.icann_base_url(Endpoint.from_packet(sp), Config.mainnet()) ==
             {:ok, "https://hs.example.org"}

    assert Endpoint.icann_base_url(
             Endpoint.from_packet(sp),
             Config.mainnet(allow_private_hosts: true)
           ) ==
             {:ok, "http://hs.example.org:8080"}
  end

  test "explicit non-default https port and z32 targets are skipped" do
    kp = Keypair.generate()
    hs = Keypair.public_z32(kp)

    records = [
      %RR{
        name: hs,
        type: 65,
        ttl: 60,
        rdata: {:https, %{priority: 1, target: Fixtures.user_z32(), params: %{}}}
      },
      %RR{
        name: hs,
        type: 65,
        ttl: 60,
        rdata: {:https, %{priority: 5, target: "hs.example.org", params: %{3 => <<8443::16>>}}}
      }
    ]

    {:ok, sp} = SignedPacket.build(kp, records)

    assert Endpoint.icann_base_url(Endpoint.from_packet(sp), Config.mainnet()) ==
             {:ok, "https://hs.example.org:8443"}

    {:ok, direct_only} = SignedPacket.build(kp, [hd(records)])

    assert Endpoint.icann_base_url(Endpoint.from_packet(direct_only), Config.mainnet()) ==
             {:error, :no_icann_endpoint}
  end
end

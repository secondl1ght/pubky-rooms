defmodule Pubky.ResolverTest do
  use ExUnit.Case, async: false

  alias Pubky.{Config, Keypair, Resolver}
  alias Pubky.Pkarr.Dns.RR
  alias Pubky.Pkarr.SignedPacket
  alias Pubky.Test.Fixtures

  setup do
    relay = Bypass.open()
    homeserver = Bypass.open()
    Resolver.clear()

    config =
      Config.mainnet(
        pkarr_relays: ["http://localhost:#{relay.port}"],
        negative_ttl: 60_000,
        allow_private_hosts: true
      )

    user = Keypair.generate()
    hs = Keypair.generate()
    hs_z32 = Keypair.public_z32(hs)

    {:ok, user_packet} =
      SignedPacket.build(user, [SignedPacket.pubky_record(Keypair.public_z32(user), hs_z32)])

    {:ok, hs_packet} =
      SignedPacket.build(hs, [
        %RR{
          name: hs_z32,
          type: 65,
          ttl: 3600,
          rdata: {:https, %{priority: 1, target: "", params: %{3 => <<6287::16>>}}}
        },
        %RR{
          name: hs_z32,
          type: 65,
          ttl: 3600,
          rdata:
            {:https,
             %{priority: 10, target: "localhost", params: %{65_280 => <<homeserver.port::16>>}}}
        }
      ])

    %{
      relay: relay,
      homeserver: homeserver,
      config: config,
      user: user,
      hs: hs,
      user_packet: user_packet,
      hs_packet: hs_packet
    }
  end

  test "resolves user → homeserver → base url + features, caching every hop", ctx do
    user_z32 = Keypair.public_z32(ctx.user)
    hs_z32 = Keypair.public_z32(ctx.hs)

    Bypass.expect_once(
      ctx.relay,
      "GET",
      "/#{user_z32}",
      &Plug.Conn.resp(&1, 200, SignedPacket.encode_relay_payload(ctx.user_packet))
    )

    Bypass.expect_once(
      ctx.relay,
      "GET",
      "/#{hs_z32}",
      &Plug.Conn.resp(&1, 200, SignedPacket.encode_relay_payload(ctx.hs_packet))
    )

    Bypass.expect_once(
      ctx.homeserver,
      "GET",
      "/info",
      &Plug.Conn.resp(&1, 200, ~s({"features":["path-addressed-storage"]}))
    )

    expected =
      {:ok, {hs_z32, "http://localhost:#{ctx.homeserver.port}", ["path-addressed-storage"]}}

    assert Resolver.base_url_for_user(user_z32, ctx.config) == expected
    # second call is served from ETS (Bypass would fail on a second request)
    assert Resolver.base_url_for_user(user_z32, ctx.config) == expected

    Resolver.invalidate(user_z32)
    Bypass.expect_once(ctx.relay, "GET", "/#{user_z32}", &Plug.Conn.resp(&1, 404, ""))
    assert Resolver.homeserver_of(user_z32, ctx.config) == {:error, :not_found}
    # negative result is cached too
    assert Resolver.homeserver_of(user_z32, ctx.config) == {:error, :not_found}
  end

  test "a packet's own TTLs shorten the cache, but never below a minute", ctx do
    hs_z32 = Keypair.public_z32(ctx.hs)

    {:ok, packet} =
      SignedPacket.build(ctx.hs, [
        %RR{
          name: hs_z32,
          type: 65,
          ttl: 0,
          rdata:
            {:https,
             %{
               priority: 10,
               target: "localhost",
               params: %{65_280 => <<ctx.homeserver.port::16>>}
             }}
        }
      ])

    Bypass.expect_once(
      ctx.relay,
      "GET",
      "/#{hs_z32}",
      &Plug.Conn.resp(&1, 200, SignedPacket.encode_relay_payload(packet))
    )

    Bypass.expect_once(ctx.homeserver, "GET", "/info", &Plug.Conn.resp(&1, 200, ~s({})))

    assert {:ok, _} = Resolver.endpoint_of(hs_z32, ctx.config)
    [{_, _, expires_at}] = :ets.lookup(:pubky_resolver, {:endpoint, hs_z32})
    assert expires_at - System.monotonic_time(:millisecond) > 55_000
  end

  test "homeserver overrides skip PKARR and /info failures degrade to no features", ctx do
    hs_z32 = Keypair.public_z32(ctx.hs)

    config = %{
      ctx.config
      | homeserver_overrides: %{hs_z32 => "http://localhost:#{ctx.homeserver.port}"}
    }

    Bypass.expect_once(ctx.homeserver, "GET", "/info", &Plug.Conn.resp(&1, 500, "nope"))

    assert Resolver.endpoint_of(hs_z32, config) ==
             {:ok, %{base_url: "http://localhost:#{ctx.homeserver.port}", features: []}}
  end

  test "packets without a _pubky record or with a bad target are reported", ctx do
    other = Keypair.generate()
    z32 = Keypair.public_z32(other)

    {:ok, empty} =
      SignedPacket.build(other, [%RR{name: z32, type: 16, ttl: 60, rdata: {:txt, ["hi"]}}])

    Bypass.expect_once(
      ctx.relay,
      "GET",
      "/#{z32}",
      &Plug.Conn.resp(&1, 200, SignedPacket.encode_relay_payload(empty))
    )

    assert Resolver.homeserver_of(z32, ctx.config) == {:error, :no_pubky_record}

    bad = Keypair.generate()
    bad_z32 = Keypair.public_z32(bad)
    {:ok, bad_packet} = SignedPacket.build(bad, [SignedPacket.pubky_record(bad_z32, "not-a-key")])

    Bypass.expect_once(
      ctx.relay,
      "GET",
      "/#{bad_z32}",
      &Plug.Conn.resp(&1, 200, SignedPacket.encode_relay_payload(bad_packet))
    )

    assert Resolver.homeserver_of(bad_z32, ctx.config) == {:error, :invalid_target}
  end

  test "concurrent misses for the same key trigger a single fetch", ctx do
    user_z32 = Keypair.public_z32(ctx.user)

    Bypass.expect_once(ctx.relay, "GET", "/#{user_z32}", fn conn ->
      Process.sleep(100)
      Plug.Conn.resp(conn, 200, SignedPacket.encode_relay_payload(ctx.user_packet))
    end)

    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Resolver.homeserver_of(user_z32, ctx.config) end) end)
      |> Task.await_many()

    assert Enum.all?(results, &(&1 == {:ok, Keypair.public_z32(ctx.hs)}))
  end

  @tag :mainnet
  test "mainnet: the official Pubky profile resolves to homeserver.pubky.app and is readable" do
    Resolver.clear()
    config = Config.mainnet()
    user = Fixtures.user_z32()

    assert {:ok, {hs, "https://homeserver.pubky.app", features}} =
             Resolver.base_url_for_user(user, config)

    assert hs == Fixtures.homeserver_z32()
    # As of 2026-09 the production homeserver predates /info and path-addressed storage,
    # so features are empty and reads must use the legacy `pubky-host` addressing.
    assert is_list(features)

    opts = Pubky.Http.pubky_host([], user)

    assert {:ok, %{body: body}} =
             Pubky.Http.request(
               :get,
               "https://homeserver.pubky.app/pub/pubky.app/profile.json",
               opts,
               config
             )

    assert {:ok, %{"name" => "Pubky"}} = JSON.decode(body)
  end
end

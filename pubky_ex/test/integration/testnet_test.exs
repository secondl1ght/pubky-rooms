defmodule Pubky.Integration.TestnetTest do
  @moduledoc """
  End-to-end checks against a local pubky-docker testnet.

      docker compose up homeserver -d      # in ~/CODE/pubky-docker
      PUBKY_TESTNET=1 mix test --include testnet
  """
  use ExUnit.Case, async: false

  @moduletag :testnet

  alias Pubky.Auth.{Capability, LocalSigner}
  alias Pubky.{Config, Keypair, Resolver, Session, Storage}
  alias Pubky.Crypto.Blake3

  setup_all do
    config = Config.testnet(client_id: "pubky-ex.test")
    Resolver.clear()
    %{config: config, homeserver: Config.testnet_homeserver()}
  end

  test "signup publishes a resolvable identity and a session can read/write", %{
    config: config,
    homeserver: hs
  } do
    user = Keypair.generate()
    z32 = Keypair.public_z32(user)

    assert :ok = LocalSigner.signup(user, hs, [], config)
    assert Resolver.homeserver_of(z32, config) == {:ok, hs}

    assert {:ok, %{base_url: "http://localhost:6286", features: features}} =
             Resolver.endpoint_of(hs, config)

    assert is_list(features)

    {:ok, cap} = Capability.read_write("/pub/pubky-ex.test/")
    assert {:ok, session} = LocalSigner.signin(user, hs, [caps: [cap]], config)

    path = "/pub/pubky-ex.test/hello.txt"
    assert :ok = Storage.put(session, path, "hi there", [content_type: "text/plain"], config)

    assert {:ok, %{body: "hi there", content_hash: hash}} =
             Storage.get(z32, path, [verify: true], config)

    assert hash == Blake3.hash("hi there")

    assert {:ok, %{entries: [%{path: ^path}]}} =
             Storage.list(z32, "/pub/pubky-ex.test/", [], config)

    assert {:error, {:http, 401, _}} = Storage.get(z32, "/priv/pubky-ex.test/x", [], config)
    assert {:error, {:http, 403, _}} = Storage.put(session, "/pub/other-app/x", "no", [], config)

    assert :ok = Storage.delete(session, path, config)
    assert Storage.get(z32, path, [], config) == {:error, :not_found}

    # durable credential → fresh bearer; forced refresh; signout revokes
    exported = Session.export(session)
    assert {:ok, restored} = Session.restore(exported, config)
    assert restored.token != session.token
    assert {:ok, refreshed} = Session.refresh(restored, config)
    assert refreshed.token != restored.token
    assert :ok = Session.signout(refreshed, config)
    assert {:error, :grant_revoked} = Session.refresh(refreshed, config)
  end

  test "live event streams deliver writes, resubscribe on membership changes, and expose cursors",
       %{config: config, homeserver: hs} do
    alice = Keypair.generate()
    bob = Keypair.generate()
    :ok = LocalSigner.signup(alice, hs, [], config)
    :ok = LocalSigner.signup(bob, hs, [], config)
    {:ok, alice_s} = LocalSigner.signin(alice, hs, [], config)
    {:ok, bob_s} = LocalSigner.signin(bob, hs, [], config)

    assert Pubky.Events.latest_cursor(hs, alice_s.user, "/pub/pubky-ex.test/", config) ==
             {:ok, nil}

    {:ok, pid} =
      Pubky.Events.start_stream(
        homeserver: hs,
        name: make_ref(),
        users: [{alice_s.user, nil}],
        paths: ["/pub/pubky-ex.test/"],
        subscriber: self(),
        config: config
      )

    assert_receive {:pubky_stream, _, :connected}, 5_000

    :ok =
      Storage.put(alice_s, "/pub/pubky-ex.test/ev1", "one", [content_type: "text/plain"], config)

    assert_receive {:pubky_event,
                    %Pubky.Events.Event{
                      type: :put,
                      path: "/pub/pubky-ex.test/ev1",
                      content_hash: h,
                      cursor: c1
                    }},
                   5_000

    assert h == Blake3.hash("one")

    assert Pubky.Events.latest_cursor(hs, alice_s.user, "/pub/pubky-ex.test/", config) ==
             {:ok, c1}

    :ok = Storage.delete(alice_s, "/pub/pubky-ex.test/ev1", config)

    assert_receive {:pubky_event,
                    %Pubky.Events.Event{type: :del, path: "/pub/pubky-ex.test/ev1", cursor: c2}},
                   5_000

    assert c2 > c1

    :ok = Pubky.Events.Stream.add_users(pid, [{bob_s.user, nil}])
    assert_receive {:pubky_stream, _, :connected}, 5_000

    :ok =
      Storage.put(bob_s, "/pub/pubky-ex.test/from-bob", "b", [content_type: "text/plain"], config)

    assert_receive {:pubky_event,
                    %Pubky.Events.Event{type: :put, path: "/pub/pubky-ex.test/from-bob"}},
                   5_000

    refute_receive {:pubky_event, %Pubky.Events.Event{cursor: ^c1}}, 200

    assert %{} = cursors = Pubky.Events.Stream.cursors(pid)
    assert cursors[alice_s.user] == c2
    Pubky.Events.Stream.stop(pid)
  end

  test "the resolver does not need the override to find the testnet homeserver", %{homeserver: hs} do
    config = Config.testnet(homeserver_overrides: %{})
    Resolver.invalidate(hs)
    assert {:ok, %{base_url: "http://localhost:6286"}} = Resolver.endpoint_of(hs, config)
  end
end

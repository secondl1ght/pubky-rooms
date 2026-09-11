defmodule Pubky.Auth.GrantFlowTest do
  use ExUnit.Case, async: true

  alias Pubky.Auth.{Capability, DeepLink, GrantFlow, LocalSigner, RelayChannel}
  alias Pubky.Auth.GrantFlow.Poller
  alias Pubky.Crypto.Blake3
  alias Pubky.{Keypair, Session, Storage}
  alias Pubky.Test.{FakeHomeserver, FakeRelay, FakeRing}

  setup do
    hs = FakeHomeserver.start()
    relay = FakeRelay.start()

    config =
      FakeHomeserver.config(hs,
        client_id: "rooms.test",
        http_relay: relay.base_url,
        flow_deadline: 5_000
      )

    user = Keypair.generate()
    :ok = LocalSigner.signup(user, hs.z32, [], config)
    %{hs: hs, relay: relay, config: config, user: user}
  end

  test "deep links round-trip and encode callbacks" do
    client = Keypair.generate()
    secret = :crypto.strong_rand_bytes(32)
    {:ok, cap} = Capability.read_write("/pub/pubky-rooms/")

    url =
      DeepLink.signin_grant(%{
        caps: [cap],
        relay: "https://httprelay.pubky.app/inbox/",
        secret: secret,
        client_id: "rooms.pubky.app",
        client_pk: Keypair.public_z32(client),
        x_callback: %{"x-source" => "Pubky Rooms", "x-success" => "https://rooms.pubky.app/?ok=1"}
      })

    assert String.starts_with?(
             url,
             "pubkyauth://signin_grant?caps=%2Fpub%2Fpubky-rooms%2F%3Arw&relay="
           )

    assert url =~ "&x-source=Pubky%20Rooms&x-success=https%3A%2F%2Frooms.pubky.app%2F%3Fok%3D1"
    assert {:ok, params} = DeepLink.parse(url)
    assert params.kind == :signin_grant
    assert params.caps == [cap]
    assert params.secret == secret
    assert params.client_id == "rooms.pubky.app"
    assert params.client_pk == Keypair.public_z32(client)

    assert params.x_callback == %{
             "x-source" => "Pubky Rooms",
             "x-success" => "https://rooms.pubky.app/?ok=1"
           }

    signup =
      DeepLink.signup_grant(%{
        caps: [cap],
        relay: "r/",
        secret: secret,
        client_id: "a",
        client_pk: params.client_pk,
        homeserver: params.client_pk,
        signup_token: "T-1"
      })

    assert {:ok, %{kind: :signup_grant, signup_token: "T-1", homeserver: hs}} =
             DeepLink.parse(signup)

    assert hs == params.client_pk

    assert DeepLink.parse("https://example.com") == {:error, :not_a_pubkyauth_url}

    assert DeepLink.parse("pubkyauth://signin?caps=/:rw") ==
             {:error, {:unsupported_intent, "signin"}}

    assert {:error, {:missing_parameter, "cpk"}} =
             DeepLink.parse(String.replace(url, ~r/&cpk=[^&]+/, ""))
  end

  test "relay channel ids and encryption" do
    secret = :crypto.strong_rand_bytes(32)

    assert RelayChannel.channel_id(secret) ==
             Base.url_encode64(Blake3.hash(secret), padding: false)

    assert String.length(RelayChannel.channel_id(secret)) == 43

    assert RelayChannel.url("http://r/inbox/", secret) ==
             "http://r/inbox/" <> RelayChannel.channel_id(secret)

    assert RelayChannel.link?("http://r/link/")
    refute RelayChannel.link?("http://r/inbox/")
    assert {:ok, "hi"} = RelayChannel.open(RelayChannel.seal("hi", secret), secret)
  end

  test "full flow: QR → fake Ring approves → session", %{
    hs: hs,
    relay: relay,
    config: config,
    user: user
  } do
    {:ok, cap} = Capability.read_write("/pub/rooms.test/")
    flow = GrantFlow.start([caps: [cap], x_callback: %{"x-source" => "Rooms"}], config)
    url = GrantFlow.authorization_url(flow)
    assert {:pending, flow} = GrantFlow.poll_once(flow)

    assert {:ok, grant} = FakeRing.approve(url, user, config)
    assert {:approved, flow} = GrantFlow.poll_once(flow)
    assert flow.grant.jti == grant.jti
    # the message was acknowledged (deleted) on the relay
    assert FakeRelay.messages(relay) == %{}

    assert {:ok, %Session{} = session, %{state: :done}} = GrantFlow.complete(flow)
    assert session.user == Keypair.public_z32(user)
    assert session.homeserver == hs.z32
    assert session.capabilities == [cap]
    assert :ok = Storage.put(session, "/pub/rooms.test/x", "1", [], config)
  end

  test "await/2 and the Poller deliver the session as a message", %{config: config, user: user} do
    flow = GrantFlow.start([caps: ["/pub/rooms.test/:rw"]], config)
    ref = make_ref()
    {:ok, _pid} = Poller.start_link(flow, notify: self(), ref: ref)
    {:ok, _} = FakeRing.approve(GrantFlow.authorization_url(flow), user, config)
    assert_receive {:pubky_auth, ^ref, {:ok, %Session{}}}, 3_000
  end

  test "a grant for a different client key or client id is rejected", %{
    config: config,
    user: user
  } do
    flow = GrantFlow.start([caps: ["/:rw"]], config)
    {:ok, params} = DeepLink.parse(GrantFlow.authorization_url(flow))
    other_client = Keypair.generate()

    grant =
      Pubky.Auth.Grant.sign(user,
        client_id: params.client_id,
        caps: params.caps,
        cnf: Keypair.public_z32(other_client)
      )

    {:ok, _} =
      Pubky.Http.request(
        :post,
        flow.channel_url,
        [body: RelayChannel.seal(grant.jws, params.secret)],
        config
      )

    assert {:error, %{state: :failed, error: :grant_mismatch}} = GrantFlow.poll_once(flow)
  end

  test "garbage on the channel fails the flow; expiry is reported", %{config: config} do
    flow = GrantFlow.start([caps: ["/:rw"]], config)
    {:ok, _} = Pubky.Http.request(:post, flow.channel_url, [body: "not encrypted"], config)
    assert {:error, %{state: :failed, error: :decrypt}} = GrantFlow.poll_once(flow)

    expired = GrantFlow.start([caps: ["/:rw"], deadline_ms: 0], config)
    Process.sleep(5)
    assert {:error, %{state: :expired, error: :expired}} = GrantFlow.poll_once(expired)
    assert GrantFlow.await(expired) == {:error, :expired}
  end

  test "save/restore resumes a pending flow", %{config: config, user: user} do
    flow = GrantFlow.start([caps: ["/pub/rooms.test/:rw"], client_id: "rooms.test"], config)
    saved = GrantFlow.save(flow)
    assert {:ok, restored} = GrantFlow.restore(saved, config)
    assert restored.channel_url == flow.channel_url
    assert restored.url == flow.url
    {:ok, _} = FakeRing.approve(restored.url, user, config)
    assert {:ok, %Session{}} = GrantFlow.await(restored, 3_000)

    assert GrantFlow.restore(%{saved | client_secret: :crypto.strong_rand_bytes(32)}, config) ==
             {:error, :client_key_mismatch}
  end

  test "signup flows create the account first", %{hs: hs, config: config} do
    newcomer = Keypair.generate()
    flow = GrantFlow.start([caps: ["/:rw"], kind: {:signup, hs.z32, nil}], config)
    {:ok, params} = DeepLink.parse(GrantFlow.authorization_url(flow))
    assert params.kind == :signup_grant and params.homeserver == hs.z32

    # Ring signs a signup grant (root caps, pubky.signup client id) for the new key
    grant =
      Pubky.Auth.Grant.sign(newcomer,
        client_id: "pubky.signup",
        caps: [Capability.root()],
        cnf: params.client_pk,
        lifetime: 300
      )

    {:ok, _} =
      Pubky.Http.request(
        :post,
        flow.channel_url,
        [body: RelayChannel.seal(grant.jws, params.secret)],
        config
      )

    flow = %{flow | client_id: "pubky.signup"}
    assert {:approved, flow} = GrantFlow.poll_once(flow)
    assert {:ok, %Session{user: user}, _} = GrantFlow.complete(flow)
    assert user == Keypair.public_z32(newcomer)
    assert user in FakeHomeserver.users(hs)
  end
end

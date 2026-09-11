defmodule Pubky.SessionTest do
  use ExUnit.Case, async: true

  alias Pubky.Auth.{Capability, Credential, LocalSigner}
  alias Pubky.Crypto.Blake3
  alias Pubky.{Keypair, Session, Storage}
  alias Pubky.Test.FakeHomeserver

  setup do
    hs = FakeHomeserver.start()
    config = FakeHomeserver.config(hs, client_id: "test.app")
    user = Keypair.generate()
    assert :ok = LocalSigner.signup(user, hs.z32, [], config)
    %{hs: hs, config: config, user: user}
  end

  test "signin yields a session that can read and write", %{hs: hs, config: config, user: user} do
    {:ok, cap} = Capability.read_write("/pub/test.app/")

    assert {:ok, session} =
             LocalSigner.signin(user, hs.z32, [caps: [cap], lifetime: 3600], config)

    assert session.user == Keypair.public_z32(user)
    assert session.homeserver == hs.z32
    assert session.client_id == "test.app"
    assert session.capabilities == [cap]
    assert session.token_expires_at > System.os_time(:second)
    refute inspect(session) =~ session.token

    assert :ok =
             Storage.put(
               session,
               "/pub/test.app/hello.txt",
               "hi",
               [content_type: "text/plain"],
               config
             )

    assert {:ok, %{body: "hi", content_type: "text/plain", content_hash: hash}} =
             Storage.get(session, "/pub/test.app/hello.txt", [verify: true], config)

    assert hash == Blake3.hash("hi")
    assert {:ok, %{"pubky" => pubky}} = Session.info(session, config)
    assert pubky == session.user
  end

  test "call/3 refreshes an expired bearer and retries once", %{
    hs: hs,
    config: config,
    user: user
  } do
    {:ok, session} = LocalSigner.signin(user, hs.z32, [], config)
    FakeHomeserver.expire_tokens(hs)

    assert {:error, {:http, 401, _}} = Storage.put(session, "/pub/test.app/x", "1", [], config)

    assert {:ok, :ok, fresh} =
             Session.call(session, &Storage.put(&1, "/pub/test.app/x", "1", [], config), config)

    assert fresh.token != session.token

    assert {:ok, %{body: "1"}, ^fresh} =
             Session.call(fresh, &Storage.get(&1, "/pub/test.app/x", [], config), config)
  end

  test "needs_refresh?/ensure_fresh honour the expiry slack", %{
    hs: hs,
    config: config,
    user: user
  } do
    {:ok, session} = LocalSigner.signin(user, hs.z32, [], config)
    refute Session.needs_refresh?(session)
    soon = %{session | token_expires_at: System.os_time(:second) + 10}
    assert Session.needs_refresh?(soon)
    assert {:ok, fresh} = Session.ensure_fresh(soon, config)
    assert fresh.token != soon.token
  end

  test "credentials export, import and restore; signout revokes", %{
    hs: hs,
    config: config,
    user: user
  } do
    {:ok, session} = LocalSigner.signin(user, hs.z32, [], config)
    exported = Session.export(session)
    assert String.starts_with?(exported, "pubky-grant-credential-v1:" <> hs.z32 <> ":")
    assert {:ok, restored} = Session.restore(exported, config)
    assert restored.user == session.user and restored.token != session.token

    assert Credential.import("nope") == {:error, :format}
    assert Credential.import("pubky-grant-credential-v9:a:b:c") == {:error, :version}
    assert Credential.import("pubky-grant-credential-v1:notakey:b:c") == {:error, :homeserver}
    assert Credential.import("pubky-grant-credential-v1:#{hs.z32}:short:c") == {:error, :secret}

    # wrong client secret cannot mint sessions
    {:ok, cred} = Credential.import(exported)

    assert Credential.restore(%{cred | client_secret: :crypto.strong_rand_bytes(32)}, config) ==
             {:error, :cnf_mismatch}

    assert :ok = Session.signout(session, config)
    assert {:error, {:http, 401, _}} = Session.info(session, config)
  end

  test "expired grants and unknown users are rejected", %{hs: hs, config: config} do
    stranger = Keypair.generate()
    assert {:error, {:http, 404, _}} = LocalSigner.signin(stranger, hs.z32, [], config)

    user = Keypair.generate()
    :ok = LocalSigner.signup(user, hs.z32, [], config)
    assert {:error, {:http, 401, _}} = LocalSigner.signin(user, hs.z32, [lifetime: -10], config)
  end
end

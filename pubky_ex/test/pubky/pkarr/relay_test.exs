defmodule Pubky.Pkarr.RelayTest do
  use ExUnit.Case, async: true

  alias Pubky.Config
  alias Pubky.Pkarr.{Relay, SignedPacket}
  alias Pubky.Test.Fixtures

  setup do
    primary = Bypass.open()
    secondary = Bypass.open()

    config =
      Config.mainnet(
        pkarr_relays: ["http://localhost:#{primary.port}", "http://localhost:#{secondary.port}"]
      )

    %{primary: primary, secondary: secondary, config: config}
  end

  test "resolves from the first relay that answers", %{primary: primary, config: config} do
    Bypass.expect_once(primary, "GET", "/" <> Fixtures.user_z32(), fn conn ->
      Plug.Conn.resp(conn, 200, Fixtures.user_payload())
    end)

    assert {:ok, sp} = Relay.resolve(Fixtures.user_z32(), config)
    assert sp.public_key == Fixtures.user_z32()
  end

  test "falls back to the next relay on errors, and 404 everywhere means not found",
       %{primary: primary, secondary: secondary, config: config} do
    Bypass.expect_once(
      primary,
      "GET",
      "/" <> Fixtures.user_z32(),
      &Plug.Conn.resp(&1, 500, "boom")
    )

    Bypass.expect_once(
      secondary,
      "GET",
      "/" <> Fixtures.user_z32(),
      &Plug.Conn.resp(&1, 200, Fixtures.user_payload())
    )

    assert {:ok, _} = Relay.resolve(Fixtures.user_z32(), config)

    Bypass.expect_once(primary, "GET", "/" <> Fixtures.user_z32(), &Plug.Conn.resp(&1, 404, ""))
    Bypass.expect_once(secondary, "GET", "/" <> Fixtures.user_z32(), &Plug.Conn.resp(&1, 404, ""))
    assert Relay.resolve(Fixtures.user_z32(), config) == {:error, :not_found}
  end

  test "a payload with a bad signature is never trusted", %{
    primary: primary,
    secondary: secondary,
    config: config
  } do
    Bypass.expect_once(
      primary,
      "GET",
      "/" <> Fixtures.user_z32(),
      &Plug.Conn.resp(&1, 200, Fixtures.homeserver_payload())
    )

    Bypass.expect_once(secondary, "GET", "/" <> Fixtures.user_z32(), &Plug.Conn.resp(&1, 500, ""))
    assert {:error, {:relay, {_, _}}} = Relay.resolve(Fixtures.user_z32(), config)

    # a 404 from another relay is authoritative: the key simply has no record
    Bypass.expect_once(
      primary,
      "GET",
      "/" <> Fixtures.user_z32(),
      &Plug.Conn.resp(&1, 200, Fixtures.homeserver_payload())
    )

    Bypass.expect_once(secondary, "GET", "/" <> Fixtures.user_z32(), &Plug.Conn.resp(&1, 404, ""))
    assert Relay.resolve(Fixtures.user_z32(), config) == {:error, :not_found}
  end

  test "publish succeeds when any relay accepts", %{
    primary: primary,
    secondary: secondary,
    config: config
  } do
    {:ok, sp} =
      SignedPacket.decode_relay_payload(Fixtures.user_z32(), Fixtures.user_payload())

    Bypass.expect_once(primary, "PUT", "/" <> Fixtures.user_z32(), &Plug.Conn.resp(&1, 500, ""))

    Bypass.expect_once(secondary, "PUT", "/" <> Fixtures.user_z32(), fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body == Fixtures.user_payload()
      Plug.Conn.resp(conn, 204, "")
    end)

    assert Relay.publish(sp, config) == :ok
  end
end

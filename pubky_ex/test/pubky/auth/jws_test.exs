defmodule Pubky.Auth.JwsTest do
  use ExUnit.Case, async: true

  alias Pubky.Auth.{Capability, Grant, Jws, Pop}
  alias Pubky.Keypair

  test "header bytes match the Rust implementation exactly" do
    assert Jws.signing_input("pubky-grant", []) |> String.split(".") |> hd() ==
             "eyJhbGciOiJFZERTQSIsInR5cCI6InB1Ymt5LWdyYW50In0"

    assert Jws.signing_input("pubky-pop", []) |> String.split(".") |> hd() ==
             "eyJhbGciOiJFZERTQSIsInR5cCI6InB1Ymt5LXBvcCJ9"
  end

  test "claims keep their order and the signature verifies" do
    kp = Keypair.generate()
    jws = Jws.sign(kp, "pubky-pop", [{"aud", "x"}, {"gid", "y"}, {"nonce", "z"}, {"iat", 1}])

    assert {:ok,
            %{
              header: %{"alg" => "EdDSA", "typ" => "pubky-pop"},
              claims: claims,
              signing_input: input
            }} = Jws.decode(jws)

    assert claims == %{"aud" => "x", "gid" => "y", "nonce" => "z", "iat" => 1}
    [_, payload] = String.split(input, ".")

    assert Base.url_decode64!(payload, padding: false) ==
             ~s({"aud":"x","gid":"y","nonce":"z","iat":1})

    assert Jws.verify(jws, kp.public)
    refute Jws.verify(jws, Keypair.generate().public)
    assert Jws.decode("not.a") == {:error, :format}
    assert Jws.decode("a.b.c") == {:error, :base64}
  end

  test "grants sign, decode, verify and validate" do
    user = Keypair.generate()
    client = Keypair.generate()
    {:ok, cap} = Capability.read_write("/pub/pubky-rooms/")

    grant =
      Grant.sign(user,
        client_id: "rooms.pubky.app",
        caps: [cap],
        cnf: Keypair.public_z32(client),
        now: 1_700_000_000,
        lifetime: 60
      )

    assert grant.iss == Keypair.public_z32(user)
    assert grant.exp == 1_700_000_060
    assert {:ok, decoded} = Grant.decode(grant.jws, verify: true)
    assert decoded == grant
    assert Grant.expired?(grant, 1_700_000_060)
    refute Grant.expired?(grant, 1_700_000_059)

    # tampered payload fails signature verification but still decodes without it
    [h, p, s] = String.split(grant.jws, ".")

    forged =
      Base.url_decode64!(p, padding: false) |> String.replace("rooms.pubky.app", "evil.example")

    forged_jws = Enum.join([h, Base.url_encode64(forged, padding: false), s], ".")
    assert {:ok, %Grant{client_id: "evil.example"}} = Grant.decode(forged_jws)
    assert Grant.decode(forged_jws, verify: true) == {:error, :bad_signature}

    # wrong typ / missing claims
    pop = Pop.sign(client, grant.iss, grant.jti)
    assert Grant.decode(pop) == {:error, :wrong_typ}

    assert {:ok, %{claims: %{"aud" => _, "gid" => _, "nonce" => nonce, "iat" => _}}} =
             Jws.decode(pop)

    assert String.length(nonce) == 22
  end

  test "capabilities parse, format and validate" do
    assert {:ok, cap} = Capability.parse("/pub/pubky-rooms/:rw")
    assert Capability.format(cap) == "/pub/pubky-rooms/:rw"
    assert to_string(Capability.root()) == "/:rw"
    assert {:ok, [_, _]} = Capability.split("/pub/a/:rw,/pub/b.txt:r")

    assert Capability.join([Capability.root(), elem(Capability.read("/pub/x"), 1)]) ==
             "/:rw,/pub/x:r"

    assert Capability.parse("pub/app:rw") == {:error, :invalid_scope}
    assert Capability.parse("/pub/app:rx") == {:error, :invalid_capability}
    assert Capability.parse("/pub/app") == {:error, :invalid_capability}
    assert Capability.parse("/pub/../etc:rw") == {:error, :invalid_scope}
  end
end

defmodule Pubky.StorageTest do
  use ExUnit.Case, async: true

  alias Pubky.Auth.LocalSigner
  alias Pubky.{Keypair, Resource, Storage}
  alias Pubky.Storage.Addressing
  alias Pubky.Test.FakeHomeserver

  defp signed_in(opts) do
    hs = FakeHomeserver.start(opts)
    config = FakeHomeserver.config(hs)
    user = Keypair.generate()
    :ok = LocalSigner.signup(user, hs.z32, [], config)
    {:ok, session} = LocalSigner.signin(user, hs.z32, [], config)
    {hs, config, session}
  end

  test "addressing picks the scheme from the advertised features" do
    assert Addressing.target("http://h", ["path-addressed-storage"], "u", "/pub/a b") ==
             {"http://h/storage/u/pub/a%20b", []}

    assert Addressing.target("http://h", [], "u", "/pub/a") ==
             {"http://h/pub/a", [{"pubky-host", "u"}]}

    assert Addressing.public_url("http://h", [], "u", "/pub/a") == "http://h/pub/a?pubky-host=u"

    assert Addressing.public_url("http://h", ["path-addressed-storage"], "u", "/pub/a") ==
             "http://h/storage/u/pub/a"
  end

  for mode <- [true, false] do
    test "crud + listing round trip (path_addressed: #{mode})" do
      {_hs, config, session} = signed_in(path_addressed: unquote(mode))
      user = session.user

      for n <- 1..3, do: :ok = Storage.put_json(session, "/pub/app/items/#{n}", %{n: n}, config)
      :ok = Storage.put(session, "/pub/app/other.txt", "x", [], config)

      assert {:ok, %{entries: entries, next_cursor: nil}} =
               Storage.list(user, "/pub/app/items/", [], config)

      assert Enum.map(entries, & &1.path) == [
               "/pub/app/items/1",
               "/pub/app/items/2",
               "/pub/app/items/3"
             ]

      assert {:ok,
              %{
                entries: [
                  %Resource{path: "/pub/app/items/3"},
                  %Resource{path: "/pub/app/items/2"}
                ],
                next_cursor: cursor
              }} =
               Storage.list(user, "/pub/app/items/", [limit: 2, reverse: true], config)

      assert cursor == "pubky://#{user}/pub/app/items/2"

      assert {:ok, %{entries: [%Resource{path: "/pub/app/items/1"}]}} =
               Storage.list(
                 user,
                 "/pub/app/items/",
                 [limit: 2, reverse: true, cursor: cursor],
                 config
               )

      assert {:ok, %{"n" => 2}} = Storage.get_json(user, "/pub/app/items/2", config)
      assert {:ok, %{etag: etag}} = Storage.head(user, "/pub/app/items/2", config)

      assert Storage.get(user, "/pub/app/items/2", [if_none_match: etag], config) ==
               {:error, :not_modified}

      assert Storage.exists?(user, "/pub/app/items/2", config)

      assert :ok = Storage.delete(session, "/pub/app/items/2", config)
      assert Storage.get(user, "/pub/app/items/2", [], config) == {:error, :not_found}
      assert Storage.delete(session, "/pub/app/items/2", config) == {:error, :not_found}
      refute Storage.exists?(user, "/pub/app/items/2", config)
    end
  end

  test "anonymous reads of /priv/ and writes without a session fail", _ do
    {_hs, config, session} = signed_in([])
    :ok = Storage.put(session, "/priv/app/secret", "s", [], config)
    assert {:error, {:http, 401, _}} = Storage.get(session.user, "/priv/app/secret", [], config)
    assert {:ok, %{body: "s"}} = Storage.get(session, "/priv/app/secret", [], config)
  end

  test "resources parse and print" do
    z = Keypair.public_z32(Keypair.generate())
    assert {:ok, %Resource{user: ^z, path: "/pub/x/y"}} = Resource.parse("pubky://#{z}/pub/x/y")
    assert to_string(Resource.new(z, "/pub/x")) == "pubky://#{z}/pub/x"
    assert Resource.parse("https://example.com") == :error
    assert Resource.parse("pubky://nope/pub/x") == :error
  end
end

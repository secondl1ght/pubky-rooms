defmodule PubkyRooms.ProfilesTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.{Fixtures, Profiles}
  alias PubkyRooms.Profiles.{Cache, LocalProfile}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.Paths

  setup do
    reset_state()
    Profiles.subscribe()
    :ok
  end

  test "unknown keys get the shortened-key fallback at once and are fetched once" do
    z32 = Fixtures.z32("nobody")
    assert %{name: name, avatar_url: nil, source: :fallback} = Profiles.get(z32)

    assert name ==
             String.upcase(String.slice(z32, 0, 4)) <>
               "…" <> String.upcase(String.slice(z32, -4, 4))

    # nothing on the homeserver: the fallback is cached, nothing is broadcast
    refute_receive {:profile_updated, ^z32, _}, 200
    assert Cache.count() == 1
    assert %{source: :fallback} = Profiles.get(z32)
  end

  test "a Pubky App profile gives the name and an https avatar" do
    z32 = Fixtures.z32("satoshi")

    Fake.seed(
      z32,
      Profiles.pubky_app_profile_path(),
      JSON.encode!(%{name: "  Satoshi ", bio: "x", image: "https://cdn.example/s.png"})
    )

    assert %{source: :fallback} = Profiles.get(z32)

    assert_receive {:profile_updated, ^z32,
                    %{
                      name: "Satoshi",
                      avatar_url: "https://cdn.example/s.png",
                      source: :pubky_app
                    }},
                   1_000

    assert %{name: "Satoshi", source: :pubky_app} = Profiles.get(z32)
  end

  test "a pubky:// image is resolved through the file record to a public URL" do
    z32 = Fixtures.z32("filer")
    file_path = "/pub/pubky.app/files/0035PERXNDXFE"
    blob_path = "/pub/pubky.app/blobs/ABCDEF"

    Fake.seed(
      z32,
      Profiles.pubky_app_profile_path(),
      JSON.encode!(%{name: "Filer", image: "pubky://#{z32}#{file_path}"})
    )

    Fake.seed(
      z32,
      file_path,
      JSON.encode!(%{name: "a.png", src: "pubky://#{z32}#{blob_path}", content_type: "image/png"})
    )

    Profiles.get(z32)
    assert_receive {:profile_updated, ^z32, %{name: "Filer", avatar_url: url}}, 1_000
    assert url =~ blob_path
    assert url =~ "pubky-host=" <> z32
  end

  test "with a Nexus CDN configured, avatars come from the CDN" do
    Application.put_env(:pubky_rooms, :nexus_cdn_url, "https://nexus.example/static/")
    on_exit(fn -> Application.put_env(:pubky_rooms, :nexus_cdn_url, nil) end)

    z32 = Fixtures.z32("cdn")

    Fake.seed(
      z32,
      Profiles.pubky_app_profile_path(),
      JSON.encode!(%{name: "Cdn", image: "https://x/y.png"})
    )

    Profiles.get(z32)
    expected = "https://nexus.example/static/avatar/" <> z32
    assert_receive {:profile_updated, ^z32, %{avatar_url: ^expected}}, 1_000

    # no image → no CDN URL either (the generative fallback is used)
    other = Fixtures.z32("cdn-noimage")
    Fake.seed(other, Profiles.pubky_app_profile_path(), JSON.encode!(%{name: "Plain"}))
    Profiles.get(other)
    assert_receive {:profile_updated, ^other, %{name: "Plain", avatar_url: nil}}, 1_000
  end

  test "the Rooms nickname is used without a Pubky App profile and refreshes on its event" do
    {sid, z32} = Fixtures.login("nick")
    Fake.seed(z32, Paths.profile(), LocalProfile.encode("nicky"))
    Profiles.get(z32)
    assert_receive {:profile_updated, ^z32, %{name: "nicky", source: :local}}, 1_000

    # the user renames: the homeserver event refreshes the cache immediately
    assert :ok = PubkyRooms.Rooms.set_nickname(sid, "renamed")
    assert_receive {:profile_updated, ^z32, %{name: "renamed", source: :local}}, 1_000

    # clearing the nickname falls back to the key
    assert :ok = PubkyRooms.Rooms.clear_nickname(sid)
    assert_receive {:profile_updated, ^z32, %{source: :fallback}}, 1_000

    # invalid names never reach the homeserver
    assert {:error, "can't be blank"} = PubkyRooms.Rooms.set_nickname(sid, "   ")
    assert {:error, _} = PubkyRooms.Rooms.set_nickname(sid, String.duplicate("x", 33))
  end

  test "garbage profiles fall back safely" do
    z32 = Fixtures.z32("garbage")
    Fake.seed(z32, Profiles.pubky_app_profile_path(), "{not json")
    Fake.seed(z32, Paths.profile(), JSON.encode!(%{v: 1, name: String.duplicate("x", 40)}))
    Profiles.get(z32)
    refute_receive {:profile_updated, ^z32, _}, 200
    assert %{source: :fallback} = Profiles.get(z32)
  end

  test "an unreachable homeserver keeps the last known profile and retries sooner" do
    z32 = Fixtures.z32("flaky")
    Cache.put(%{pubky: z32, name: "Known", avatar_url: nil, source: :pubky_app}, -1)
    Fake.fail_get(z32, :unreachable)
    assert %{name: "Known"} = Profiles.get(z32)
    Process.sleep(50)
    assert %{name: "Known"} = Profiles.get(z32)
    assert [{^z32, _, _, 60_000}] = :ets.lookup(Profiles.table(), z32)
  end
end

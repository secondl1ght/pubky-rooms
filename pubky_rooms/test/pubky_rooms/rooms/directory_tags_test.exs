defmodule PubkyRooms.Rooms.DirectoryTagsTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.{Fixtures, Nexus, Rooms}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.{Directory, Paths, Room}
  alias PubkyRooms.Tags.Tag

  setup do
    reset_state()
    Directory.subscribe()
    {sid, alice} = Fixtures.login("alice")
    %{sid: sid, alice: alice}
  end

  test "a public room is created with universal tags; unlisted rooms get none", %{
    sid: sid,
    alice: alice
  } do
    assert {:error, [tags: {"Add up to 4 tags.", []}]} =
             Rooms.create_room(sid, alice, %{
               "name" => "Too many",
               "visibility" => "public",
               "tags" => "a b c d e"
             })

    {:ok, room} =
      Rooms.create_room(sid, alice, %{
        "name" => "Tagged",
        "visibility" => "public",
        "tags" => "#Bitcoin, dev"
      })

    ref = Room.ref(room)
    uri = Room.uri(room)

    for label <- ["room", "bitcoin", "dev"] do
      assert {:ok, %{label: ^label, room_ref: ^ref}} =
               Tag.decode(Fake.files(alice)[Tag.path(uri, label)], Tag.path(uri, label))
    end

    assert Enum.map(Directory.tags_of(ref), & &1.label) == ["bitcoin", "dev", "room"]
    assert Directory.own_tags(ref, alice) == ["bitcoin", "dev", "room"]
    assert Directory.popular_tags() == [{"bitcoin", 1}, {"dev", 1}, {"room", 1}]
    assert Directory.rooms_tagged("dev") == [ref]

    {:ok, unlisted} =
      Rooms.create_room(sid, alice, %{
        "name" => "Hidden",
        "visibility" => "unlisted",
        "tags" => "x"
      })

    refute Fake.files(alice)
           |> Map.keys()
           |> Enum.any?(&String.contains?(&1, Tag.id(Room.uri(unlisted), "room")))

    assert Directory.tags_of(Room.ref(unlisted)) == []
  end

  test "tags written by other clients arrive through events and sign-in sync; deletions too",
       ctx do
    %{sid: sid, alice: alice} = ctx
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Room", "visibility" => "public"})
    ref = Room.ref(room)
    uri = Room.uri(room)
    bob = Fixtures.z32("tagger-bob")
    flush()

    # live event
    Fake.write_as(bob, Tag.path(uri, "music"), Tag.encode(uri, "music"))
    assert_receive {:directory, {:tags_updated, ^ref}}, 1_000
    assert Directory.tagged_by?(ref, "music", bob)
    assert [%{label: "music", count: 1, taggers: [^bob]} | _] = Directory.tags_of(ref)

    # garbage in our namespace is ignored (wrong id for its content)
    Fake.write_as(bob, Tag.path(uri, "wrong"), Tag.encode(uri, "other"))
    refute_receive {:directory, {:tags_updated, ^ref}}, 200
    refute Directory.tagged_by?(ref, "other", bob)

    # a tag on a URI that is not a room is ignored
    post = "pubky://#{bob}/pub/pubky.app/posts/0035PERXNDXFE"
    Fake.write_as(bob, Tag.path(post, "x"), Tag.encode(post, "x"))
    refute_receive {:directory, {:tags_updated, _}}, 200

    # deletion
    Fake.delete_as(bob, Tag.path(uri, "music"))
    assert_receive {:directory, {:tags_updated, ^ref}}, 1_000
    refute Directory.tagged_by?(ref, "music", bob)

    # seeded before this node saw the user: picked up on sign-in sync
    carol = Fixtures.z32("tagger-carol")
    Fake.seed(carol, Tag.path(uri, "nostr"), Tag.encode(uri, "nostr"))
    Directory.sync_user(carol, force: true)
    assert_receive {:directory, {:tags_updated, ^ref}}, 2_000
    assert Directory.tagged_by?(ref, "nostr", carol)
  end

  test "users tag and untag rooms; visibility flips and closing manage the creator's tags", ctx do
    %{sid: sid, alice: alice} = ctx
    {bob_sid, bob} = Fixtures.login("bob")
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Room", "visibility" => "public"})
    ref = Room.ref(room)
    uri = Room.uri(room)

    assert {:ok, "lightning"} = Rooms.tag_room(bob_sid, bob, ref, " Lightning ")
    assert Map.has_key?(Fake.files(bob), Tag.path(uri, "lightning"))
    assert Directory.tagged_by?(ref, "lightning", bob)
    assert {:error, "Enter a tag."} = Rooms.tag_room(bob_sid, bob, ref, "  ")

    assert :ok = Rooms.untag_room(bob_sid, bob, ref, "lightning")
    refute Map.has_key?(Fake.files(bob), Tag.path(uri, "lightning"))
    refute Directory.tagged_by?(ref, "lightning", bob)

    # unlisting removes the creator's tags; bob's stay (they are his files) but
    # nobody can add new ones; relisting restores "room"
    assert {:ok, "lightning"} = Rooms.tag_room(bob_sid, bob, ref, "lightning")

    {:ok, room} =
      Rooms.update_room(sid, alice, room, %{"name" => "Room", "visibility" => "unlisted"})

    assert Directory.own_tags(ref, alice) == []
    refute Map.has_key?(Fake.files(alice), Tag.path(uri, "room"))
    assert Enum.map(Directory.tags_of(ref), & &1.label) == ["lightning"]
    assert {:error, "Unlisted rooms have no tags."} = Rooms.tag_room(bob_sid, bob, ref, "new")
    assert {:error, "Unlisted rooms have no tags."} = Rooms.tag_room(sid, alice, ref, "room")
    assert :ok = Rooms.untag_room(bob_sid, bob, ref, "lightning")
    assert Directory.tags_of(ref) == []

    {:ok, room} =
      Rooms.update_room(sid, alice, room, %{"name" => "Room", "visibility" => "public"})

    assert Directory.own_tags(ref, alice) == ["room"]

    # closing deletes the creator's tag files too
    assert :ok = Rooms.close_room(sid, alice, room)
    refute Map.has_key?(Fake.files(alice), Tag.path(uri, "room"))
    assert Directory.tags_of(ref) == []
  end

  test "Nexus resources are merged: unknown rooms are learned and tagger counts shown", ctx do
    %{sid: sid, alice: alice} = ctx
    {:ok, room} = Rooms.create_room(sid, alice, %{"name" => "Known", "visibility" => "public"})
    ref = Room.ref(room)
    # a room this node has never seen, but its creator's homeserver has it
    stranger = Fixtures.z32("nexus-stranger")
    {:ok, far} = Room.new(stranger, %{"name" => "Far away", "visibility" => "public"})
    Fake.seed(stranger, Paths.room(far.id), Room.encode(far))
    Directory.reset()
    Directory.put_room(room)
    assert Directory.get(Room.ref(far)) == nil

    Application.put_env(:pubky_rooms, :nexus_url, "http://nexus.test")
    Application.put_env(:pubky_rooms, :nexus_req_options, plug: {Req.Test, Nexus})

    on_exit(fn ->
      Application.delete_env(:pubky_rooms, :nexus_url)
      Application.delete_env(:pubky_rooms, :nexus_req_options)
    end)

    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(Nexus, fn conn ->
      assert conn.request_path == "/v0/stream/resources"
      assert conn.query_params["app"] == "pubky-rooms"

      Req.Test.json(conn, [
        %{
          "details" => %{"uri" => Room.uri(room), "id" => "x"},
          "tags" => [%{"label" => "room", "taggers" => [alice], "taggers_count" => 7}],
          "taggers_count" => 7
        },
        %{
          "details" => %{"uri" => Room.uri(far)},
          "tags" => [%{"label" => "travel", "taggers_count" => 2}],
          "taggers_count" => 2
        },
        %{
          "details" => %{"uri" => "pubky://#{alice}/pub/pubky.app/posts/0035PERXNDXFE"},
          "tags" => []
        }
      ])
    end)

    assert Nexus.enabled?()
    Directory.sync_nexus()
    assert_receive {:directory, {:tags_updated, ^ref}}, 2_000
    far_ref = Room.ref(far)
    assert_receive {:directory, {:tags_updated, ^far_ref}}, 2_000

    # counts come from Nexus (taggers are only the ones this node saw itself)
    assert [%{label: "room", count: 7}] = Directory.tags_of(ref)
    assert [%{label: "travel", count: 2, taggers: []}] = Directory.tags_of(far_ref)
    assert wait_until(fn -> match?(%Room{name: "Far away"}, Directory.get(far_ref)) end)
    assert far_ref in Directory.rooms_tagged("travel")
    assert Enum.map(Directory.public_rooms(), & &1.name) |> Enum.sort() == ["Far away", "Known"]
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
  end
end

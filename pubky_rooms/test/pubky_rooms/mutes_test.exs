defmodule PubkyRooms.MutesTest do
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.{Fixtures, Mutes}
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.Rooms.Paths

  setup do
    reset_state()
    :ok
  end

  test "mute paths are recognised" do
    bob = Fixtures.z32("bob")
    assert Paths.mute(bob) == "/pub/pubky-rooms/mutes/" <> bob
    assert Paths.parse(Paths.mute(bob)) == {:mute, bob}
    assert Paths.parse("/pub/pubky-rooms/mutes/not-a-key") == :ignore
  end

  test "lists come from the Rooms and Pubky App mute folders; a user without either has none" do
    alice = Fixtures.z32("alice")
    assert Mutes.of(alice) == %{own: MapSet.new(), app: MapSet.new()}

    bob = Fixtures.z32("bob")
    carol = Fixtures.z32("carol")
    Fake.seed(alice, Mutes.app_mutes_dir() <> bob, ~s({"created_at":1}))
    Fake.seed(alice, Mutes.app_mutes_dir() <> "junk", "x")
    Fake.seed(alice, Paths.mute(carol), ~s({"v":1,"created_at":1}))

    Mutes.reset()
    assert %{own: own, app: app} = Mutes.of(alice)
    assert own == MapSet.new([carol])
    assert app == MapSet.new([bob])
    assert Mutes.all(alice) == MapSet.new([bob, carol])
  end

  test "mute writes a marker, unmute deletes it, both update the cache and announce" do
    {sid, alice} = Fixtures.login("alice")
    bob = Fixtures.z32("bob")
    Mutes.subscribe(alice)
    assert Mutes.all(alice) == MapSet.new()
    assert_receive {:mutes_updated, ^alice}

    assert :ok = Mutes.mute(sid, alice, bob)
    assert Map.has_key?(Fake.files(alice), Paths.mute(bob))
    assert Mutes.all(alice) == MapSet.new([bob])
    assert_receive {:mutes_updated, ^alice}

    assert :ok = Mutes.unmute(sid, alice, bob)
    refute Map.has_key?(Fake.files(alice), Paths.mute(bob))
    assert Mutes.all(alice) == MapSet.new()
    assert_receive {:mutes_updated, ^alice}

    # already gone counts as done; muting yourself or garbage is refused
    assert :ok = Mutes.unmute(sid, alice, bob)
    assert {:error, :invalid_target} = Mutes.mute(sid, alice, alice)
    assert {:error, :invalid_target} = Mutes.mute(sid, alice, "nope")
  end

  test "markers written by another client (or device) update a cached list live" do
    alice = Fixtures.z32("alice")
    erin = Fixtures.z32("erin")
    Mutes.subscribe(alice)
    assert Mutes.all(alice) == MapSet.new()
    assert_receive {:mutes_updated, ^alice}

    Fake.write_as(alice, Paths.mute(erin), ~s({"v":1,"created_at":1}))
    assert_receive {:mutes_updated, ^alice}, 1_000
    assert Mutes.all(alice) == MapSet.new([erin])

    Fake.delete_as(alice, Paths.mute(erin))
    assert_receive {:mutes_updated, ^alice}, 1_000
    assert Mutes.all(alice) == MapSet.new()
  end

  test "mutes are rate limited per session" do
    {sid, alice} = Fixtures.login("alice")

    for i <- 1..20 do
      assert :ok = Mutes.mute(sid, alice, Fixtures.z32("target-#{i}"))
    end

    assert {:error, {:rate_limited, _}} = Mutes.mute(sid, alice, Fixtures.z32("target-21"))
  end
end

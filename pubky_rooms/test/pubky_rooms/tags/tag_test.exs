defmodule PubkyRooms.Tags.TagTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Ids
  alias PubkyRooms.Rooms.Paths
  alias PubkyRooms.Tags.Tag

  @creator "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
  @uri "pubky://#{@creator}/pub/pubky-rooms/rooms/0035PERXNDXFE"

  test "crockford encodes without padding characters" do
    assert Ids.crockford(<<0>>) == "00"
    assert Ids.crockford(<<255>>) == "ZW"
    assert Ids.crockford(:binary.copy(<<0>>, 16)) == String.duplicate("0", 26)
    # a timestamp id is the same encoding of 8 bytes + one zero bit
    assert Ids.crockford(<<1_789_185_340_721_000::64>>) == Ids.encode(1_789_185_340_721_000)
  end

  test "ids are 26-char hash ids derived from uri and label" do
    id = Tag.id(@uri, "bitcoin")
    assert String.length(id) == 26
    assert {:tag, ^id} = Paths.parse(Tag.path(@uri, "bitcoin"))
    assert id != Tag.id(@uri, "music")
    assert id == Tag.id(@uri, "bitcoin")
  end

  test "labels are normalized like pubky-app-specs" do
    assert {:ok, "bitcoin"} = Tag.normalize("  BitCoin ")
    assert {:error, _} = Tag.normalize("")
    assert {:error, _} = Tag.normalize(String.duplicate("a", 21))
    assert {:error, _} = Tag.normalize("a/b")
    assert {:ok, ["bitcoin", "nostr", "dev"]} = Tag.parse_labels("#Bitcoin, nostr  dev room")
    assert {:error, "at most 2 tags"} = Tag.parse_labels("a b c", 2)
    assert {:ok, []} = Tag.parse_labels(nil)
    assert {:ok, []} = Tag.parse_labels("   ")
  end

  test "decode checks the id against the content and finds the room" do
    path = Tag.path(@uri, "bitcoin")

    assert {:ok, %{label: "bitcoin", uri: @uri, room_ref: {@creator, "0035PERXNDXFE"}}} =
             Tag.decode(Tag.encode(@uri, "bitcoin"), path)

    # wrong id for the content
    assert {:error, :id_mismatch} = Tag.decode(Tag.encode(@uri, "music"), path)
    # a tag on something that is not a room still decodes, without a room ref
    other = "pubky://#{@creator}/pub/pubky.app/posts/0035PERXNDXFE"
    assert {:ok, %{room_ref: nil}} = Tag.decode(Tag.encode(other, "x"), Tag.path(other, "x"))
    # labels must be stored normalized
    bad = JSON.encode!(%{uri: @uri, label: "Bitcoin", created_at: 1})
    assert {:error, :label_not_normalized} = Tag.decode(bad, path)
  end
end

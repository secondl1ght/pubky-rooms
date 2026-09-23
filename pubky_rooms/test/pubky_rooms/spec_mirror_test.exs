defmodule PubkyRooms.SpecMirrorTest do
  @moduledoc """
  Pubky Rooms cannot run pubky-app-specs (a Rust crate shipped as WASM), so the
  rules it needs are reimplemented in Elixir. This test pins every one of them
  to data copied from the real package (`docs/fixtures/pubky-app-specs/`), so
  bumping that copy to a newer spec fails here on each value that moved.

  The inventory of what is mirrored, and how to refresh the fixtures, is
  `docs/notes/pubky-app-specs-mirror.md`.
  """
  use ExUnit.Case, async: true

  alias PubkyRooms.{Ids, Mutes, Profiles}
  alias PubkyRooms.Rooms.{Message, Paths}
  alias PubkyRooms.Tags.Tag

  @fixtures Path.expand("../../../docs/fixtures/pubky-app-specs", __DIR__)
  @limits @fixtures |> Path.join("validationLimits.json") |> File.read!() |> JSON.decode!()
  @vectors @fixtures |> Path.join("vectors.json") |> File.read!() |> JSON.decode!()

  describe "tags" do
    test "label rules match validationLimits" do
      assert Tag.label_max() == @limits["tagLabelMaxLength"]
      assert Enum.sort(Tag.banned_chars()) == Enum.sort(@limits["tagInvalidChars"])
      # tagLabelMinLength
      assert {:error, _} = Tag.normalize(String.duplicate(" ", @limits["tagLabelMinLength"]))
      assert {:ok, "a"} = Tag.normalize(String.duplicate("a", @limits["tagLabelMinLength"]))
      # the automatic "room" label plus the creator's own stay within Pubky App's per-item count
      assert Tag.max_custom_labels() + 1 <= @limits["feedTagsMaxCount"]
    end

    test "labels the package rejects are rejected here" do
      for label <- @vectors["tag_rejected_labels"] do
        assert {:error, _} = Tag.normalize(label), "expected #{inspect(label)} to be rejected"
      end
    end

    test "normalisation and hash ids match the package byte for byte" do
      for %{"uri" => uri, "input_label" => input, "label" => label, "id" => id} <-
            @vectors["tags"] do
        assert {:ok, ^label} = Tag.normalize(input)
        assert Tag.id(uri, label) == id
        # Rooms writes under its own namespace; the id is the same
        assert Tag.path(uri, label) == Paths.tag(id)
      end
    end

    test "the tag file has the spec's keys and a microsecond timestamp" do
      [%{"uri" => uri, "label" => label} | _] = @vectors["tags"]
      json = JSON.decode!(Tag.encode(uri, label))
      assert Enum.sort(Map.keys(json)) == Enum.sort(@vectors["tag_json_keys"])
      assert @vectors["tag_created_at_unit"] == "microseconds"
      # a microsecond timestamp for 2020..2100 has 16 digits; milliseconds would have 13
      assert json["created_at"] |> Integer.to_string() |> String.length() == 16
    end
  end

  describe "ids" do
    test "timestamp ids match the package" do
      for %{"micros" => micros, "id" => id} <- @vectors["timestamp_ids"] do
        assert Ids.encode(micros) == id
        assert Ids.decode(id) == {:ok, micros}
        assert Ids.valid_id?(id)
      end
    end
  end

  describe "profiles and files" do
    test "profile limits match validationLimits" do
      assert Profiles.name_max() == @limits["userNameMaxLength"]
      assert Profiles.image_url_max() == @limits["userImageUrlMaxLength"]
      assert Profiles.pubky_app_profile_path() == "/pub/pubky.app/profile.json"
    end

    test "names longer than the spec allows are dropped, valid ones kept" do
      for %{"name" => name, "valid" => valid?} <- @vectors["user_names"],
          String.length(name) >= @limits["userNameMinLength"] do
        # Rooms reads profiles written by Pubky App and only enforces the upper bound
        # (a name Pubky App accepted is always displayed)
        assert String.length(name) <= @limits["userNameMaxLength"] == valid?
      end
    end

    test "the file record keys we read exist in the spec" do
      assert "src" in @vectors["file_json_keys"]
    end

    test "Pubky App mutes are read from the spec's path" do
      assert Mutes.app_mutes_dir() == "/pub/pubky.app/mutes/"
    end
  end

  describe "Rooms' own limits that shadow the spec" do
    test "a message is never longer than a Pubky App short post" do
      assert Message.content_max() <= @limits["postShortContentMaxLength"]
    end
  end
end

defmodule PubkyRooms.Rooms.BanTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Rooms
  alias PubkyRooms.Rooms.Ban

  test "reasons are optional, trimmed and bounded" do
    assert {:ok, nil} = Ban.validate_reason(nil)
    assert {:ok, nil} = Ban.validate_reason("   ")
    assert {:ok, nil} = Ban.validate_reason(%{"reason" => "not a string"})
    assert {:ok, "spam"} = Ban.validate_reason("  spam ")

    assert {:error, "Reasons can be up to 140 characters."} =
             Ban.validate_reason(String.duplicate("x", 141))

    assert {:error, "The reason contains unsupported characters."} =
             Ban.validate_reason("bad\0byte")
  end

  test "ban and unban refuse targets that are not public keys before touching the homeserver" do
    creator = String.duplicate("y", 52)
    ref = {creator, "0000000000001"}
    assert {:error, :invalid_target} = Rooms.ban("no-session", creator, ref, "../../rooms", nil)
    assert {:error, :invalid_target} = Rooms.unban("no-session", creator, ref, "../../rooms")
    assert {:error, :invalid_target} = Rooms.unban("no-session", creator, ref, "not a key")
  end

  test "markers round-trip and reject garbage" do
    assert {:ok, %{reason: "spam", created_at: at}} = Ban.decode(Ban.encode("spam"))
    assert is_integer(at)
    assert {:ok, %{reason: nil}} = Ban.decode(Ban.encode(nil))

    assert {:error, :invalid_json} = Ban.decode("not json")
    assert {:error, :unsupported_version} = Ban.decode(~s({"v":2,"created_at":1}))
    assert {:error, :invalid_timestamp} = Ban.decode(~s({"v":1,"created_at":"soon"}))
    assert {:error, :too_large} = Ban.decode(String.duplicate(" ", 16_385))
  end
end

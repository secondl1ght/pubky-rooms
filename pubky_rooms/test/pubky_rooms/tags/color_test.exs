defmodule PubkyRooms.Tags.ColorTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Tags.Color

  # Vectors computed with the reference JavaScript implementation (Node 24).
  @vectors [
    {"test", "#0092FF"},
    {"test1", "#00FFdf"},
    {"test2", "#FF00e0"},
    {"hello world", "#c4FF00"},
    {"Pubky Rooms", "#FF8300"},
    {"a", "#FF6100"},
    {"", "#FF0000"},
    {"😀tag", "#00FF3d"},
    {"café", "#2100FF"},
    {"elixir", "#00FF41"},
    {"phoenix", "#00FF71"},
    {"sovereign live chat rooms on pubky with a long label", "#00FF5d"}
  ]

  test "matches the reference implementation" do
    for {label, expected} <- @vectors do
      assert Color.hex(label) == expected, "label #{inspect(label)}"
    end
  end

  test "brand labels are fixed and case-insensitive" do
    assert Color.hex("bitcoin") == "#FF9900"
    assert Color.hex("BiTcOiN") == "#FF9900"
    assert Color.hex("pubky") == "#C8FF00"
    assert Color.hex("tether") == "#26A17B"
  end

  test "rgb and css_rgb decode the hex" do
    assert Color.rgb("bitcoin") == {255, 153, 0}
    assert Color.css_rgb("test") == "0 146 255"
  end
end

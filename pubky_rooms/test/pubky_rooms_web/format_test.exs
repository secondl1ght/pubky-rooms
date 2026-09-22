defmodule PubkyRoomsWeb.FormatTest do
  use ExUnit.Case, async: true

  alias PubkyRoomsWeb.Format

  @now 1_789_185_340_000

  test "relative times are compact" do
    assert Format.relative(nil, @now) == ""
    assert Format.relative(@now - 10_000, @now) == "just now"
    assert Format.relative(@now - 5 * 60_000, @now) == "5m"
    assert Format.relative(@now - 3 * 3_600_000, @now) == "3h"
    assert Format.relative(@now - 2 * 86_400_000, @now) == "2d"
    assert Format.relative(@now - 30 * 86_400_000, @now) =~ ~r/^[A-Z][a-z]{2} \d{1,2}$/
  end

  test "clock and iso render UTC timestamps" do
    assert Format.clock(0) == "00:00"
    assert Format.iso(0) == "1970-01-01T00:00:00.000Z"
  end

  test "truncate flattens whitespace and adds an ellipsis when cutting" do
    assert Format.truncate("short  text\nhere", 100) == "short text here"
    assert Format.truncate(String.duplicate("a", 20), 10) == String.duplicate("a", 9) <> "…"
    assert String.length(Format.truncate(String.duplicate("é", 300), 140)) == 140
  end
end

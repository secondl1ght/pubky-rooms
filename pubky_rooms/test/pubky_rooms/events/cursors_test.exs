defmodule PubkyRooms.Events.CursorsTest do
  use ExUnit.Case, async: false

  alias PubkyRooms.Events.Cursors

  setup do
    Cursors.reset()
    :ok
  end

  test "advance only moves forward; put is unconditional" do
    assert Cursors.get("u1") == nil
    assert Cursors.advance("u1", 5)
    refute Cursors.advance("u1", 5)
    refute Cursors.advance("u1", 3)
    assert Cursors.advance("u1", 9)
    assert Cursors.get("u1") == 9

    assert :ok = Cursors.put("u1", 2)
    assert Cursors.get("u1") == 2
    assert :ok = Cursors.put("u2", nil)
    assert Cursors.get("u2") == nil
  end

  test "rows untouched for longer than the TTL are swept; fresh ones stay" do
    Cursors.put("old", 1)
    Cursors.put("fresh", 1)
    assert Cursors.count() == 2

    # nothing is old enough with the default TTL
    assert Cursors.sweep() == 0

    Application.put_env(:pubky_rooms, :cursor_ttl_ms, 50)
    on_exit(fn -> Application.delete_env(:pubky_rooms, :cursor_ttl_ms) end)
    Process.sleep(60)
    Cursors.advance("fresh", 2)
    assert Cursors.sweep() == 1
    assert Cursors.get("old") == nil
    assert Cursors.get("fresh") == 2
  end
end

defmodule PubkyRooms.Rooms.ExplainTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.Rooms

  test "a rate limit says how long to wait, in seconds or in whole minutes" do
    assert Rooms.explain({:rate_limited, 0}) == "Slow down — try again in 1 s."
    assert Rooms.explain({:rate_limited, 4_500}) == "Slow down — try again in 4 s."
    assert Rooms.explain({:rate_limited, 119_000}) == "Slow down — try again in 119 s."
    assert Rooms.explain({:rate_limited, 120_000}) == "Slow down — try again in 2 min."
    assert Rooms.explain({:rate_limited, 1_973_000}) == "Slow down — try again in 33 min."
    assert Rooms.explain({:rate_limited, 3_600_000}) == "Slow down — try again in 60 min."
  end

  test "the other reasons are sentences" do
    assert Rooms.explain(:unauthorized) == "Your session has expired. Please sign in again."
    assert Rooms.explain("already a sentence") == "already a sentence"
    assert Rooms.explain({:http, 507}) == "Your homeserver answered with status 507."
  end
end

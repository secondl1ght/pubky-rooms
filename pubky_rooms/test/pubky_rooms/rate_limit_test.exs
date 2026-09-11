defmodule PubkyRooms.RateLimitTest do
  use ExUnit.Case, async: true

  alias PubkyRooms.RateLimit

  test "allows limit hits per window, then rejects with a retry hint" do
    key = {:test, make_ref()}
    for _ <- 1..3, do: assert(RateLimit.check(key, 3, 60_000) == :ok)
    assert {:error, {:rate_limited, ms}} = RateLimit.check(key, 3, 60_000)
    assert ms > 0 and ms <= 60_000
    assert RateLimit.check({:other, make_ref()}, 3, 60_000) == :ok
  end
end

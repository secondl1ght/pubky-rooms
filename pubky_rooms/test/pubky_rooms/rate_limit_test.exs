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

  test "once/2 accepts a key a single time until it is swept" do
    key = {:handoff, make_ref()}
    assert RateLimit.once(key, 60_000) == :ok
    assert RateLimit.once(key, 60_000) == {:error, :used}
    assert RateLimit.once({:handoff, make_ref()}, 60_000) == :ok

    # an expired key is swept and may be used again
    expired = {:handoff, make_ref()}
    assert RateLimit.once(expired, 1) == :ok
    Process.sleep(5)
    send(RateLimit, :sweep)
    Process.sleep(20)
    assert RateLimit.once(expired, 60_000) == :ok
  end
end

defmodule PubkyRooms.RoomsCase do
  @moduledoc """
  Test case for anything touching the fake homeserver, the directory or the
  rate limiter: all of them are global, so these tests run `async: false`
  and reset the shared state with `reset_state/0`.
  """
  use ExUnit.CaseTemplate

  alias PubkyRooms.Events.Cursors
  alias PubkyRooms.Pubky.Fake
  alias PubkyRooms.RateLimit
  alias PubkyRooms.Rooms.Directory

  using do
    quote do
      import PubkyRooms.RoomsCase
    end
  end

  @doc "Clears the fake homeserver, directory, cursors and rate limits."
  def reset_state do
    Fake.reset()
    Directory.reset()
    Cursors.reset()
    RateLimit.reset()
    :ok
  end
end

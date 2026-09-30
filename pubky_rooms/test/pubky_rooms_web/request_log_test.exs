defmodule PubkyRoomsWeb.RequestLogTest do
  use PubkyRoomsWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PubkyRooms.Fixtures

  @z32 "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"

  # ADR 0006: nothing at `info` and above carries a user's public key. Room
  # paths do, so the request lines must stay below `info`.
  test "request paths with public keys are not logged at info", %{conn: conn} do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      log = capture_log(fn -> get(conn, "/r/#{@z32}/0035S410XTQJC") end)
      refute log =~ @z32
      refute log =~ "GET /r/"
    after
      Logger.configure(level: level)
    end

    _ = Fixtures
  end
end

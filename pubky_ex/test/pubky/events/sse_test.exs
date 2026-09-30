defmodule Pubky.Events.SSETest do
  use ExUnit.Case, async: true

  alias Pubky.Events.{Event, SSE}

  @user "ihaqcthsdbk751sxctk849bdr7yz7a934qen5gmpcbwcur49i97y"
  @hash Base.encode64(:binary.copy(<<1>>, 32))

  test "parses frames, comments, CRLF and chunk boundaries" do
    stream =
      "event: PUT\ndata: pubky://#{@user}/pub/app/a\ndata: cursor: 42\ndata: content_hash: #{@hash}\n\n" <>
        ": keep-alive\r\n\r\n" <>
        "event: DEL\r\ndata: pubky://#{@user}/pub/app/b\r\ndata: cursor: 43\r\n\r\n" <>
        "event: PUT\ndata:pubky://#{@user}/pub/app/c\ndata: cursor: 44\ndata: content_hash: #{@hash}\n\n"

    # feed in awkward pieces
    {frames, parser} =
      stream
      |> String.graphemes()
      |> Enum.chunk_every(7)
      |> Enum.map(&Enum.join/1)
      |> Enum.reduce({[], SSE.new()}, fn chunk, {acc, p} ->
        {f, p} = SSE.feed(p, chunk)
        {acc ++ f, p}
      end)

    assert parser.buffer == ""
    assert [%{event: "PUT", data: d1}, %{event: "DEL"}, %{event: "PUT", data: d3}] = frames
    assert d1 == "pubky://#{@user}/pub/app/a\ncursor: 42\ncontent_hash: #{@hash}"
    assert String.starts_with?(d3, "pubky://#{@user}/pub/app/c")

    assert {:ok,
            %Event{
              type: :put,
              user: @user,
              path: "/pub/app/a",
              cursor: 42,
              content_hash: <<1, _::binary>>
            }} =
             Event.from_frame(Enum.at(frames, 0), "hs")

    assert {:ok, %Event{type: :del, cursor: 43, content_hash: nil}} =
             Event.from_frame(Enum.at(frames, 1), "hs")
  end

  test "lines and frames beyond max_bytes are refused instead of buffered" do
    max = SSE.max_bytes()

    # a line that never ends
    assert SSE.feed(SSE.new(), String.duplicate("a", max + 1)) == {:error, :frame_too_large}
    # a complete line that is too long
    assert SSE.feed(SSE.new(), "data: " <> String.duplicate("a", max + 1) <> "\n") ==
             {:error, :frame_too_large}

    # data lines that add up past the cap within one frame
    half = String.duplicate("b", div(max, 2) + 1)
    assert {[], parser} = SSE.feed(SSE.new(), "data: #{half}\n")
    assert SSE.feed(parser, "data: #{half}\n") == {:error, :frame_too_large}

    # the same data split across two frames is fine
    assert {[%{data: ^half}], parser} = SSE.feed(SSE.new(), "data: #{half}\n\n")
    assert {[%{data: ^half}], _} = SSE.feed(parser, "data: #{half}\n\n")
  end

  test "defaults, unknown fields and malformed frames" do
    {[%{event: "message", data: "x", id: "7"}], _} =
      SSE.feed(SSE.new(), "id: 7\nfoo: bar\ndata: x\n\n")

    {[], _} = SSE.feed(SSE.new(), "event: PUT\n\n")

    assert {:error, {:unknown_event, "message"}} =
             Event.from_frame(%{event: "message", data: "x", id: nil}, "hs")

    assert {:error, :missing_content_hash} =
             Event.from_frame(
               %{event: "PUT", data: "pubky://#{@user}/pub/x\ncursor: 1", id: nil},
               "hs"
             )

    assert {:error, :missing_cursor} =
             Event.from_frame(%{event: "DEL", data: "pubky://#{@user}/pub/x", id: nil}, "hs")

    assert {:error, {:invalid_uri, _}} =
             Event.from_frame(%{event: "DEL", data: "nope\ncursor: 1", id: nil}, "hs")
  end
end

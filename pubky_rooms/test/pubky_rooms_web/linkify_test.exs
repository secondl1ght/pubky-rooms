defmodule PubkyRoomsWeb.LinkifyTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PubkyRoomsWeb.Linkify

  test "splits text into text and link segments, keeping trailing punctuation outside" do
    assert Linkify.segments("plain words") == [text: "plain words"]

    assert Linkify.segments("see https://pubky.org/docs, and http://a.b/c?d=1&e=2.") == [
             text: "see ",
             link: "https://pubky.org/docs",
             text: ", and ",
             link: "http://a.b/c?d=1&e=2",
             text: "."
           ]

    assert Linkify.segments("(https://en.wikipedia.org/wiki/Bitcoin_(song))") == [
             text: "(",
             link: "https://en.wikipedia.org/wiki/Bitcoin_(song)",
             text: ")"
           ]

    # pubky:// and bare domains stay text
    assert Linkify.segments("pubky://abc/pub/x and example.com") ==
             [text: "pubky://abc/pub/x and example.com"]
  end

  test "renders escaped text and safe anchors" do
    html =
      render_component(&Linkify.linkify/1,
        text: "<b>x</b> https://pubky.org/?a=1&b=2 <script>"
      )

    assert html =~ "&lt;b&gt;x&lt;/b&gt;"
    assert html =~ ~s(href="https://pubky.org/?a=1&amp;b=2")
    assert html =~ ~s(rel="noopener noreferrer nofollow ugc")
    assert html =~ ~s(target="_blank")
    refute html =~ "<script>"
    refute html =~ "<b>"

    # exactly the text's whitespace, nothing added around the anchor
    assert render_component(&Linkify.linkify/1, text: "a https://x.y b") ==
             ~s(a <a href="https://x.y" rel="noopener noreferrer nofollow ugc" target="_blank" class="text-brand underline decoration-brand/40 hover:decoration-brand">https://x.y</a> b)
  end
end

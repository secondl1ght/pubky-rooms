defmodule PubkyRoomsWeb.UI.AvatarTest do
  use PubkyRoomsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PubkyRoomsWeb.UI.Avatar

  test "the picture sits over the fallback, marked for the page-level error listener, with no DOM id" do
    html =
      render_component(&Avatar.avatar/1, src: "https://cdn.test/a.png", name: "Alice", pubky: "a")

    assert html =~ ~s(<img src="https://cdn.test/a.png")
    assert html =~ "data-avatar"
    assert html =~ "aria-hidden"
    refute html =~ "phx-hook"
    # the same picture may be rendered several times on one page (composer,
    # members, rows): an id derived from the URL made duplicates that broke patching
    refute html =~ "id=\"avatar-img"
  end

  test "without a picture the initial on a signal colour is the whole avatar" do
    html = render_component(&Avatar.avatar/1, name: "Bob", pubky: "b")
    refute html =~ "<img"
    assert html =~ ~r/>\s*B\s*</
    refute html =~ "aria-hidden"
  end
end

defmodule PubkyRoomsWeb.ErrorHTMLTest do
  use PubkyRoomsWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html as a styled page with a way back" do
    html = render_to_string(PubkyRoomsWeb.ErrorHTML, "404", "html", [])
    assert html =~ "<title>Page not found · Pubky Rooms</title>"
    assert html =~ ~s(href="/assets/css/app.css")
    assert html =~ "Page not found"
    assert html =~ ~r/<a href="\/" class="[^"]*">Back to the lobby<\/a>/
  end

  test "renders 500.html as a styled page" do
    html = render_to_string(PubkyRoomsWeb.ErrorHTML, "500", "html", [])
    assert html =~ "Something went wrong"
    assert html =~ "Back to the lobby"
  end

  test "other statuses keep Phoenix's plain text" do
    assert render_to_string(PubkyRoomsWeb.ErrorHTML, "403", "html", []) == "Forbidden"
  end
end

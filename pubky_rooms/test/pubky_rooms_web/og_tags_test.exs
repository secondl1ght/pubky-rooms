defmodule PubkyRoomsWeb.OgTagsTest do
  use PubkyRoomsWeb.ConnCase, async: false
  use PubkyRooms.RoomsCase, async: false

  alias PubkyRooms.{Fixtures, Rooms}
  alias PubkyRoomsWeb.Meta

  setup do
    reset_state()
    :ok
  end

  defp meta(html, attr, name) do
    case Regex.run(~r{<meta #{attr}="#{Regex.escape(name)}" content="([^"]*)"}, html) do
      [_, content] -> unescape(content)
      nil -> nil
    end
  end

  # attribute values are HTML-escaped in the document; read them back as text
  defp unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
  end

  defp base, do: PubkyRoomsWeb.Endpoint.url()

  test "the lobby carries the site preview with the brand image", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert meta(html, "property", "og:title") == "Pubky Rooms · Live rooms. Your homeserver."
    assert meta(html, "property", "og:description") == Meta.default_description()
    assert meta(html, "name", "description") == Meta.default_description()
    assert meta(html, "property", "og:url") == base() <> "/"
    assert meta(html, "property", "og:image") == base() <> "/images/og.png"
    assert meta(html, "property", "og:image:width") == "1200"
    assert meta(html, "name", "twitter:card") == "summary_large_image"
    assert meta(html, "name", "twitter:image") == base() <> "/images/og.png"
    assert File.exists?("priv/static/images/og.png")
  end

  test "a room previews with its name and topic, or a sentence about rooms", %{conn: conn} do
    {sid, alice} = Fixtures.login("alice")

    {:ok, with_topic} =
      Rooms.create_room(sid, alice, %{
        "name" => "Lightning talk",
        "topic" => "Tuesday's <demo> & questions",
        "visibility" => "public"
      })

    {:ok, bare} = Rooms.create_room(sid, alice, %{"name" => "Quiet", "visibility" => "public"})

    html = conn |> get(~p"/r/#{alice}/#{with_topic.id}") |> html_response(200)
    assert meta(html, "property", "og:title") == "Lightning talk · Pubky Rooms"
    assert meta(html, "property", "og:description") == "Tuesday's <demo> & questions"
    assert meta(html, "property", "og:url") == base() <> "/r/#{alice}/#{with_topic.id}"

    html = conn |> get(~p"/r/#{alice}/#{bare.id}") |> html_response(200)
    assert meta(html, "property", "og:title") == "Quiet · Pubky Rooms"

    assert meta(html, "property", "og:description") ==
             "Join Quiet, a live room on Pubky Rooms. Every message stays on its author's homeserver."

    assert :ok = Rooms.close_room(sid, alice, bare)
    html = conn |> get(~p"/r/#{alice}/#{bare.id}") |> html_response(200)
    assert meta(html, "property", "og:description") =~ "Quiet is closed: a read-only room"

    # a room nobody knows previews as the site itself
    html = conn |> get(~p"/r/#{alice}/0035S410XTQ00") |> html_response(200)
    assert meta(html, "property", "og:title") == "Pubky Rooms"
    assert meta(html, "property", "og:description") == Meta.default_description()
    assert html =~ "<title" and html =~ ">Pubky Rooms</title>"
  end

  test "sign-in and account pages describe themselves", %{conn: conn} do
    html = conn |> get(~p"/login") |> html_response(200)
    assert meta(html, "property", "og:title") == "Sign in · Pubky Rooms"
    assert meta(html, "property", "og:description") =~ "Sign in with Pubky Ring"

    {sid, _me} = Fixtures.login("me")
    html = conn |> init_test_session(Fixtures.cookie(sid)) |> get(~p"/me") |> html_response(200)
    assert meta(html, "property", "og:title") == "You · Pubky Rooms"
    assert meta(html, "property", "og:description") =~ "Your Pubky Rooms account"
  end

  test "Meta falls back sensibly" do
    assert Meta.document_title(%{}) == "Pubky Rooms"
    assert Meta.document_title(%{page_title: "Slice"}) == "Slice · Pubky Rooms"
    assert Meta.title(%{}) == "Pubky Rooms"
    assert Meta.title(%{page_title: nil}) == "Pubky Rooms"
    assert Meta.title(%{page_title: "Lobby"}) == "Pubky Rooms · Live rooms. Your homeserver."
    assert Meta.title(%{page_title: "Slice"}) == "Slice · Pubky Rooms"
    assert Meta.description(%{page_description: ""}) == Meta.default_description()
    assert Meta.description(%{page_description: "Topic"}) == "Topic"
  end
end

defmodule PubkyRoomsWeb.Meta do
  @moduledoc """
  What link previews show for a page (Open Graph and Twitter cards): a title
  and a description computed from the assigns a LiveView sets before its
  dead render (`page_title`, `page_description`), and one static brand image.

  Crawlers only ever see the dead render, so every LiveView sets these in
  `mount/3` (the room page from what the directory knows about the room).
  """

  @site "Pubky Rooms"
  @tagline "Live rooms. Your homeserver."
  @default_description "Group chat where every message is yours to keep. Sign in with Pubky Ring, open a room, share the link. Nothing here is locked in."
  @room_description "A live room on Pubky Rooms: every message stays on its author's homeserver."

  @doc "The site name."
  def site, do: @site

  @doc "The one-line tagline (also on the share image)."
  def tagline, do: @tagline

  @doc "The description used when a page sets none."
  def default_description, do: @default_description

  @doc "The description of a room without a topic."
  def room_description, do: @room_description

  @doc "The preview title: the page title with the site name, or the site name alone for the lobby."
  @spec title(map()) :: String.t()
  def title(%{page_title: title}) when is_binary(title) and title not in ["", "Lobby"],
    do: "#{title} · #{@site}"

  def title(_assigns), do: "#{@site} · #{@tagline}"

  @doc "The preview description: the page's own, or the default."
  @spec description(map()) :: String.t()
  def description(%{page_description: text}) when is_binary(text) and text != "", do: text
  def description(_assigns), do: @default_description
end

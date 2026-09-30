defmodule PubkyRoomsWeb.ErrorHTML do
  @moduledoc """
  Error pages for HTML requests (`config :pubky_rooms, PubkyRoomsWeb.Endpoint,
  render_errors: …`). `404` and `500` are full documents in the app's styling,
  rendered without a layout because the error may come from the layout stack
  itself; every other status falls back to Phoenix's plain status text.
  """
  use PubkyRoomsWeb, :html

  embed_templates "error_html/*"

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

defmodule PubkyRoomsWeb.LobbyLive do
  @moduledoc """
  The lobby: your rooms, rooms you joined, and public rooms to discover.

  Placeholder while the vertical slice is being built.
  """
  use PubkyRoomsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Rooms", current_user: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:lobby}>
      <.page>
        <.empty_state icon="lucide-messages-square" title="No rooms yet">
          Rooms are live chats stored on the members' own homeservers.
          <:actions>
            <.button variant="brand" navigate={~p"/rooms/new"}>
              <.icon name="lucide-plus" class="size-4" /> Create a room
            </.button>
          </:actions>
        </.empty_state>
      </.page>
    </Layouts.app>
    """
  end
end

defmodule PubkyRooms.Rooms do
  @moduledoc """
  The rooms context: creating rooms, joining them, sending messages.

  Every write goes to the acting user's homeserver through `PubkyRooms.Pubky`;
  the app's own state (directory, room caches) is updated from the resulting
  homeserver events, exactly as it would be for any other client.
  """

  @doc "Called when a signed-in user's LiveView connects: keeps their events flowing."
  @spec on_user_connected(String.t()) :: :ok
  def on_user_connected(_pubky), do: :ok
end

defmodule PubkyRoomsWeb.Flash do
  @moduledoc """
  One place that turns a failed write into a toast. A rate limit is not a
  failure but something to wait out, so it shows as a warning (amber, dismisses
  itself); every other reason is an error (red, stays until closed). The text
  comes from `PubkyRooms.Rooms.explain/1`, with an optional prefix such as
  "Tag not saved: ".
  """

  alias PubkyRooms.Rooms

  @doc "Puts the toast for `reason` on the socket: a warning for a rate limit, an error otherwise."
  @spec put_failure(Phoenix.LiveView.Socket.t(), term(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def put_failure(socket, reason, prefix \\ "") do
    Phoenix.LiveView.put_flash(socket, kind(reason), prefix <> Rooms.explain(reason))
  end

  defp kind({:rate_limited, _ms}), do: :warning
  defp kind(_reason), do: :error
end

defmodule PubkyRooms.Events do
  @moduledoc """
  Homeserver events inside the app.

  Every `Pubky.Events.Stream` this node runs delivers events to
  `PubkyRooms.Events.Subscriptions`, which hands them to `dispatch/1`.
  Dispatch advances the per-user cursor (dropping replays after a reconnect)
  and broadcasts `{:pubky_event, %Pubky.Events.Event{}}` on two PubSub topics:

    * `pubky:user:<z32>` — everything one user wrote or deleted
    * `pubky:all` — everything, for the room directory
  """

  alias PubkyRooms.Events.Cursors

  @pubsub PubkyRooms.PubSub

  @doc "The PubSub topic for one user's events."
  @spec user_topic(String.t()) :: String.t()
  def user_topic(z32), do: "pubky:user:" <> z32

  @doc "The PubSub topic carrying every event."
  @spec all_topic() :: String.t()
  def all_topic, do: "pubky:all"

  def subscribe_user(z32), do: Phoenix.PubSub.subscribe(@pubsub, user_topic(z32))
  def unsubscribe_user(z32), do: Phoenix.PubSub.unsubscribe(@pubsub, user_topic(z32))
  def subscribe_all, do: Phoenix.PubSub.subscribe(@pubsub, all_topic())

  @doc "Advances the user's cursor and broadcasts the event; `:stale` if it was already seen."
  @spec dispatch(Pubky.Events.Event.t()) :: :ok | :stale
  def dispatch(%Pubky.Events.Event{} = ev) do
    if Cursors.advance(ev.user, ev.cursor) do
      Phoenix.PubSub.broadcast(@pubsub, user_topic(ev.user), {:pubky_event, ev})
      Phoenix.PubSub.broadcast(@pubsub, all_topic(), {:pubky_event, ev})
      :ok
    else
      :stale
    end
  end
end

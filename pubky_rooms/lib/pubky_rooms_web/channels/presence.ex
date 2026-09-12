defmodule PubkyRoomsWeb.Presence do
  @moduledoc """
  Who is here right now: the ephemeral layer Pubky itself has no concept of.

  Signed-in viewers are tracked per room (`presence:room:<creator>/<id>`) and
  across the app (`presence:lobby`), keyed by public key with one meta per
  open tab (`%{joined_at}` only; names come from the profiles cache).
  Anonymous viewers are never tracked, only counted by the room server.
  Nothing here is written anywhere: presence lives in the tracker's memory
  and vanishes with the LiveView.

  Instead of the raw `presence_diff` message, subscribers of a topic (see
  `subscribe/1`) receive `{:presence, {:join | :leave, %{key, metas}}}` per
  key from `handle_metas/4`; a leave with empty `metas` means the last tab
  closed.
  """
  use Phoenix.Presence,
    otp_app: :pubky_rooms,
    pubsub_server: PubkyRooms.PubSub

  alias PubkyRooms.Rooms.Paths

  @doc "The presence topic of a room."
  @spec room_topic(Paths.room_ref()) :: String.t()
  def room_topic({creator, id}), do: "presence:room:#{creator}/#{id}"

  @doc "The app-wide presence topic (signed-in users with Rooms open anywhere)."
  @spec lobby_topic() :: String.t()
  def lobby_topic, do: "presence:lobby"

  @doc "Tracks the calling LiveView as `user` in the room."
  @spec track_room(Paths.room_ref(), map()) :: {:ok, binary()} | {:error, term()}
  def track_room(ref, user), do: track_user(room_topic(ref), user)

  @doc "Tracks the calling LiveView as `user` app-wide."
  @spec track_lobby(map()) :: {:ok, binary()} | {:error, term()}
  def track_lobby(user), do: track_user(lobby_topic(), user)

  defp track_user(topic, %{pubky: z32}),
    do: track(self(), topic, z32, %{joined_at: System.os_time(:millisecond)})

  @doc "Subscribes the caller to `{:presence, …}` messages for the topic."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic), do: Phoenix.PubSub.subscribe(PubkyRooms.PubSub, "proxy:" <> topic)

  @doc "The users present on a topic: `%{z32 => [meta]}`."
  @spec online(String.t()) :: %{String.t() => [map()]}
  def online(topic), do: topic |> list() |> Map.new(fn {key, %{metas: metas}} -> {key, metas} end)

  @doc "How many distinct users are present on a topic."
  @spec online_count(String.t()) :: non_neg_integer()
  def online_count(topic), do: topic |> list() |> map_size()

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_metas(topic, %{joins: joins, leaves: leaves}, presences, state) do
    for {key, _} <- joins do
      broadcast(topic, {:join, %{key: key, metas: metas_of(presences, key)}})
    end

    for {key, _} <- leaves do
      broadcast(topic, {:leave, %{key: key, metas: metas_of(presences, key)}})
    end

    {:ok, state}
  end

  # `presences` in `handle_metas/4` maps key → metas (a list; a map with
  # `:metas` when `fetch/2` is customized).
  defp metas_of(presences, key) do
    case presences do
      %{^key => %{metas: metas}} -> metas
      %{^key => metas} when is_list(metas) -> metas
      _ -> []
    end
  end

  defp broadcast(topic, event),
    do: Phoenix.PubSub.local_broadcast(PubkyRooms.PubSub, "proxy:" <> topic, {:presence, event})
end

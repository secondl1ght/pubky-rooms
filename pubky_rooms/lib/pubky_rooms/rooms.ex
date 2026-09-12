defmodule PubkyRooms.Rooms do
  @moduledoc """
  The rooms context: creating rooms, joining them, sending messages.

  Every write goes to the acting user's homeserver through `PubkyRooms.Pubky`;
  the app's own state (directory, room caches) is updated from the resulting
  homeserver events, exactly as it would be for any other client. Writes are
  rate-limited per login session.
  """

  alias PubkyRooms.{Events, Pubky, RateLimit}
  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.Profiles.LocalProfile
  alias PubkyRooms.Rooms.{Directory, Membership, Message, Paths, Room, RoomServer}

  @type sid :: String.t()

  @doc "Called when a signed-in user's LiveView connects: keeps their events flowing."
  @spec on_user_connected(String.t()) :: :ok
  def on_user_connected(pubky) do
    Subscriptions.acquire([pubky], self())
    Events.subscribe_user(pubky)
    Directory.sync_user(pubky)
  end

  @doc """
  Creates a room on the creator's homeserver (room definition + the creator's
  own join marker) and records it locally.
  """
  @spec create_room(sid(), String.t(), map()) ::
          {:ok, Room.t()} | {:error, keyword() | Pubky.reason()}
  def create_room(sid, creator, attrs) do
    with {:ok, room} <- Room.new(creator, attrs),
         :ok <- limit({:rooms, sid}, 5, :timer.hours(1)),
         ref = Room.ref(room),
         :ok <- Pubky.put(sid, Paths.room(room.id), Room.encode(room)),
         :ok <- Pubky.put(sid, Paths.member(ref), Membership.encode(ref)) do
      Directory.put_room(room)
      {:ok, room}
    end
  end

  @doc "Joins a room by writing a join marker on the user's homeserver."
  @spec join(sid(), String.t(), Paths.room_ref()) :: :ok | {:error, Pubky.reason()}
  def join(sid, user, ref) do
    with :ok <- limit({:joins, sid}, 20, :timer.hours(1)),
         :ok <- Pubky.put(sid, Paths.member(ref), Membership.encode(ref)) do
      Directory.add_member(ref, user)
    end
  end

  @doc "Leaves a room by deleting the join marker."
  @spec leave(sid(), String.t(), Paths.room_ref()) :: :ok | {:error, Pubky.reason()}
  def leave(sid, user, ref) do
    with :ok <- Pubky.delete(sid, Paths.member(ref)) do
      Directory.remove_member(ref, user)
    end
  end

  @doc "The PubSub topic carrying `{:typing, z32, boolean}` for a room. Never persisted."
  @spec typing_topic(Paths.room_ref()) :: String.t()
  def typing_topic({creator, id}), do: "room:#{creator}/#{id}:typing"

  @doc "Tells the room's viewers whether `z32` is typing."
  @spec broadcast_typing(Paths.room_ref(), String.t(), boolean()) :: :ok
  def broadcast_typing(ref, z32, typing?) do
    Phoenix.PubSub.broadcast(PubkyRooms.PubSub, typing_topic(ref), {:typing, z32, typing?})
  end

  @doc "How many signed-in users have the room open right now."
  @spec online_count(Paths.room_ref()) :: non_neg_integer()
  def online_count(ref),
    do: ref |> PubkyRoomsWeb.Presence.room_topic() |> PubkyRoomsWeb.Presence.online_count()

  @doc "Signed-in presence of a room: distinct `users` and their open `tabs`."
  @spec online_stats(Paths.room_ref()) :: %{users: non_neg_integer(), tabs: non_neg_integer()}
  def online_stats(ref) do
    online = ref |> PubkyRoomsWeb.Presence.room_topic() |> PubkyRoomsWeb.Presence.online()
    %{users: map_size(online), tabs: online |> Map.values() |> Enum.map(&length/1) |> Enum.sum()}
  end

  @doc """
  How many viewers have the room open right now, signed in or not (a count of
  LiveView processes attached to the room server; nothing identifies them).
  """
  @spec viewer_count(Paths.room_ref()) :: non_neg_integer()
  def viewer_count(ref), do: RoomServer.viewer_count(ref)

  @doc "The PubSub topic carrying `{:room_stats, ref, %{viewers: n}}` for a room."
  @spec stats_topic(Paths.room_ref()) :: String.t()
  def stats_topic(ref), do: RoomServer.stats_topic(ref)

  @doc """
  Viewers who are not signed in: the room's viewer total minus the open tabs
  of signed-in users (`online` maps z32 → tabs). Never negative.
  """
  @spec anonymous_count(non_neg_integer(), %{String.t() => non_neg_integer()}) ::
          non_neg_integer()
  def anonymous_count(viewers, online), do: max(viewers - Enum.sum(Map.values(online)), 0)

  @doc """
  Sets the user's Rooms nickname (`/pub/pubky-rooms/profile.json`), shown when
  they have no Pubky App profile.
  """
  @spec set_nickname(sid(), String.t()) :: :ok | {:error, String.t() | Pubky.reason()}
  def set_nickname(sid, name) do
    with {:ok, name} <- LocalProfile.validate(name),
         :ok <- limit({:nickname, sid}, 10, :timer.minutes(10)) do
      Pubky.put(sid, Paths.profile(), LocalProfile.encode(name))
    end
  end

  @doc "Removes the user's Rooms nickname."
  @spec clear_nickname(sid()) :: :ok | {:error, Pubky.reason()}
  def clear_nickname(sid) do
    case Pubky.delete(sid, Paths.profile()) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  @doc "Whether the user may post in the room (creator or known member)."
  @spec member?(Paths.room_ref(), String.t() | nil) :: boolean()
  def member?(_ref, nil), do: false
  def member?(ref, user), do: Directory.member?(ref, user)

  @doc """
  Validates and registers a new message as pending with the room server, so
  the homeserver's PUT event can confirm it by content hash. Returns the
  message to render optimistically; then call `publish_message/2`.
  """
  @spec prepare_message(sid(), String.t(), Paths.room_ref(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, String.t() | {:rate_limited, pos_integer()}}
  def prepare_message(sid, author, ref, content, opts \\ []) do
    with :ok <- limit({:messages, sid}, 5, 5_000),
         {:ok, msg} <- Message.new(author, ref, content, opts) do
      :ok = RoomServer.register_pending(ref, msg, RoomServer.content_hash(Message.encode(msg)))
      {:ok, msg}
    end
  end

  @doc """
  Prepares an edit of the author's own message: same id and path, new content,
  `edited_at` set. Registered as pending so the PUT event confirms it; then
  call `publish_message/2`.
  """
  @spec prepare_edit(sid(), Message.t(), String.t()) ::
          {:ok, Message.t()} | {:error, String.t() | {:rate_limited, pos_integer()}}
  def prepare_edit(sid, %Message{} = msg, content) do
    with :ok <- limit({:messages, sid}, 5, 5_000),
         {:ok, content} <- Message.validate_content(content) do
      edited = %{
        msg
        | content: content,
          edited_at: System.os_time(:millisecond),
          state: :pending,
          fail_reason: nil
      }

      :ok =
        RoomServer.register_pending(
          msg.room_ref,
          edited,
          RoomServer.content_hash(Message.encode(edited))
        )

      {:ok, edited}
    end
  end

  @doc "Deletes the author's own message from their homeserver (already gone counts as done)."
  @spec delete_message(sid(), Message.t()) :: :ok | {:error, Pubky.reason()}
  def delete_message(sid, %Message{} = msg) do
    case Pubky.delete(sid, Message.path(msg)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  @doc "Writes a prepared message to the author's homeserver."
  @spec publish_message(sid(), Message.t()) :: :ok | {:error, Pubky.reason()}
  def publish_message(sid, %Message{} = msg) do
    case Pubky.put(sid, Message.path(msg), Message.encode(msg)) do
      :ok ->
        :ok

      {:error, reason} ->
        RoomServer.cancel_pending(msg.room_ref, msg.key)
        {:error, reason}
    end
  end

  @doc "Retries a failed message with the same id and content."
  @spec retry_message(sid(), Message.t()) :: {:ok, Message.t()} | {:error, Pubky.reason()}
  def retry_message(sid, %Message{} = msg) do
    msg = %{msg | state: :pending, fail_reason: nil}

    :ok =
      RoomServer.register_pending(msg.room_ref, msg, RoomServer.content_hash(Message.encode(msg)))

    case publish_message(sid, msg) do
      :ok -> {:ok, msg}
      error -> error
    end
  end

  @doc "A human explanation of a homeserver write failure."
  @spec explain(term()) :: String.t()
  def explain(:quota), do: "Your homeserver is out of storage."
  def explain(:too_large), do: "That is too large for your homeserver."
  def explain({:rate_limited, ms}), do: "Slow down — try again in #{max(div(ms, 1000), 1)} s."
  def explain(:unauthorized), do: "Your session has expired. Please sign in again."
  def explain(:unreachable), do: "Your homeserver could not be reached."
  def explain({:http, status}), do: "Your homeserver answered with status #{status}."
  def explain(reason) when is_binary(reason), do: reason
  def explain(reason), do: "Something went wrong (#{inspect(reason)})."

  defp limit(key, count, window) do
    case RateLimit.check(key, count, window) do
      :ok -> :ok
      {:error, {:rate_limited, ms}} -> {:error, {:rate_limited, ms}}
    end
  end
end

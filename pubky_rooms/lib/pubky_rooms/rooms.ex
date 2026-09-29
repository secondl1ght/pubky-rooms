defmodule PubkyRooms.Rooms do
  @moduledoc """
  The rooms context: creating rooms, joining them, sending messages.

  Every write goes to the acting user's homeserver through `PubkyRooms.Pubky`;
  the app's own state (directory, room caches) is updated from the resulting
  homeserver events, exactly as it would be for any other client. Writes are
  rate-limited per login session.
  """

  require Logger

  alias PubkyRooms.{Events, Pubky, RateLimit}
  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.Profiles.LocalProfile
  alias PubkyRooms.Rooms.{Ban, Directory, Membership, Message, Paths, Reaction, Room, RoomServer}
  alias PubkyRooms.Tags.Tag

  @max_own_tags 10

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
  own join marker) and records it locally. Public rooms also get universal
  tags for discovery: the automatic `room` label plus up to
  #{Tag.max_custom_labels()} labels from `attrs["tags"]` (ADR 0003); tag
  writes are best effort.
  """
  @spec create_room(sid(), String.t(), map()) ::
          {:ok, Room.t()} | {:error, keyword() | Pubky.reason()}
  def create_room(sid, creator, attrs) do
    with {:ok, labels} <- room_labels(attrs),
         {:ok, room} <- Room.new(creator, attrs),
         :ok <- limit({:rooms, sid}, 5, :timer.hours(1)),
         ref = Room.ref(room),
         :ok <- Pubky.put(sid, Paths.room(room.id), Room.encode(room)),
         :ok <- Pubky.put(sid, Paths.member(ref), Membership.encode(ref)) do
      Directory.put_room(room)

      if room.visibility == "public",
        do: write_tags(sid, creator, ref, [Tag.auto_label() | labels])

      {:ok, room}
    end
  end

  defp room_labels(attrs) do
    case Tag.parse_labels(Room.field(attrs, "tags")) do
      {:ok, labels} -> {:ok, labels}
      {:error, reason} -> {:error, [tags: {reason, []}]}
    end
  end

  defp write_tags(sid, user, ref, labels) do
    uri = Paths.room_uri(ref)

    for label <- labels do
      case Pubky.put(sid, Tag.path(uri, label), Tag.encode(uri, label)) do
        :ok -> Directory.add_tag(ref, label, user, Tag.id(uri, label))
        {:error, reason} -> Logger.debug("tag not written: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp delete_tags(sid, user, ref, labels) do
    uri = Paths.room_uri(ref)

    for label <- labels do
      case Pubky.delete(sid, Tag.path(uri, label)) do
        ok when ok in [:ok, {:error, :not_found}] ->
          Directory.remove_tag(user, Tag.id(uri, label))

        {:error, reason} ->
          Logger.debug("tag not deleted: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Tags a room: writes a `PubkyAppTag` in the user's own Rooms namespace (any
  signed-in user, 20 per hour, at most #{@max_own_tags} labels per room).
  """
  @spec tag_room(sid(), String.t(), Paths.room_ref(), String.t()) ::
          {:ok, String.t()} | {:error, String.t() | Pubky.reason()}
  def tag_room(sid, user, ref, label) do
    with {:ok, label} <- Tag.normalize(label),
         true <- listed?(Directory.get(ref)) || {:error, "Unlisted rooms have no tags."},
         true <-
           length(Directory.own_tags(ref, user)) < @max_own_tags ||
             {:error, "at most #{@max_own_tags} tags per room"},
         :ok <- limit({:tags, sid}, 20, :timer.hours(1)),
         uri = Paths.room_uri(ref),
         :ok <- Pubky.put(sid, Tag.path(uri, label), Tag.encode(uri, label)) do
      Directory.add_tag(ref, label, user, Tag.id(uri, label))
      {:ok, label}
    end
  end

  # A room this node has not indexed yet is given the benefit of the doubt.
  defp listed?(%Room{visibility: "unlisted"}), do: false
  defp listed?(_room), do: true

  @doc "Removes the user's own tag from a room (already gone counts as done)."
  @spec untag_room(sid(), String.t(), Paths.room_ref(), String.t()) ::
          :ok | {:error, String.t() | Pubky.reason()}
  def untag_room(sid, user, ref, label) do
    with {:ok, label} <- Tag.normalize(label) do
      delete_tags(sid, user, ref, [label])
    end
  end

  @doc """
  Updates a room's name, topic or visibility: the creator overwrites the room
  definition on their homeserver (same id, `created_at` kept; 20 per hour).
  """
  @spec update_room(sid(), String.t(), Room.t(), map()) ::
          {:ok, Room.t()} | {:error, keyword() | Pubky.reason() | :forbidden}
  def update_room(sid, creator, %Room{creator: creator} = room, attrs) do
    with {:ok, fields} <- Room.validate(attrs),
         :ok <- limit({:room_updates, sid}, 20, :timer.hours(1)),
         updated = %{room | name: fields.name, topic: fields.topic, visibility: fields.visibility},
         :ok <- Pubky.put(sid, Paths.room(room.id), Room.encode(updated)) do
      Directory.put_room(updated)
      ref = Room.ref(room)

      case {room.visibility, updated.visibility} do
        {"public", "unlisted"} -> delete_tags(sid, creator, ref, Directory.own_tags(ref, creator))
        {"unlisted", "public"} -> write_tags(sid, creator, ref, [Tag.auto_label()])
        _ -> :ok
      end

      {:ok, updated}
    end
  end

  def update_room(_sid, _user, _room, _attrs), do: {:error, :forbidden}

  @doc """
  Closes a room: the creator deletes the room definition (and their own tags
  on it). Members' messages stay on their homeservers and the room lives on
  as a read-only archive for its members (`Directory.close_room/1`).
  """
  @spec close_room(sid(), String.t(), Room.t()) :: :ok | {:error, Pubky.reason() | :forbidden}
  def close_room(sid, creator, %Room{creator: creator} = room) do
    ref = Room.ref(room)

    case Pubky.delete(sid, Paths.room(room.id)) do
      ok when ok in [:ok, {:error, :not_found}] ->
        delete_tags(sid, creator, ref, Directory.own_tags(ref, creator))
        Directory.close_room(ref)
        :ok

      error ->
        error
    end
  end

  def close_room(_sid, _user, _room), do: {:error, :forbidden}

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

  @doc """
  Reacts to a message: writes a marker on the reactor's homeserver. Only the
  v1 palette is written; 20 reactions per 10 s per session.
  """
  @spec react(sid(), Message.t(), String.t()) :: :ok | {:error, term()}
  def react(sid, %Message{} = msg, key) do
    with true <- Reaction.writable?(key) || {:error, :invalid_reaction},
         :ok <- limit({:reactions, sid}, 20, 10_000) do
      Pubky.put(sid, Paths.reaction(msg.room_ref, msg.author, msg.msg_id, key), Reaction.encode())
    end
  end

  @doc "Removes the session user's reaction marker (already gone counts as done)."
  @spec unreact(sid(), Message.t(), String.t()) :: :ok | {:error, term()}
  def unreact(sid, %Message{} = msg, key) do
    with :ok <- limit({:reactions, sid}, 20, 10_000) do
      case Pubky.delete(sid, Paths.reaction(msg.room_ref, msg.author, msg.msg_id, key)) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        error -> error
      end
    end
  end

  @doc """
  Removes a member from the room: the creator writes a ban marker on their own
  homeserver (20 per hour). `creator` must be the session's user and the room's
  creator; the creator cannot ban themselves.
  """
  @spec ban(sid(), String.t(), Paths.room_ref(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def ban(sid, creator, {creator, id}, banned, reason) when banned != creator do
    with {:ok, reason} <- Ban.validate_reason(reason),
         :ok <- limit({:bans, sid}, 20, :timer.hours(1)) do
      Pubky.put(sid, Paths.ban(id, banned), Ban.encode(reason))
    end
  end

  def ban(_sid, _user, _ref, _banned, _reason), do: {:error, :forbidden}

  @doc "Lifts a ban by deleting the marker (already gone counts as done)."
  @spec unban(sid(), String.t(), Paths.room_ref(), String.t()) :: :ok | {:error, term()}
  def unban(sid, creator, {creator, id}, banned) do
    case Pubky.delete(sid, Paths.ban(id, banned)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  def unban(_sid, _user, _ref, _banned), do: {:error, :forbidden}

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
  def explain(:invalid_reaction), do: "That reaction is not available."
  def explain(:forbidden), do: "Only the room's creator can do that."
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

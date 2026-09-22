defmodule PubkyRooms.Rooms.Paths do
  @moduledoc """
  The on-homeserver layout of Pubky Rooms (namespace `/pub/pubky-rooms/`).

      rooms/<room_id>                                        RoomDef (creator only)
      members/<creator>/<room_id>                            JoinMarker
      messages/<creator>/<room_id>/<msg_id>                  Message
      reactions/<creator>/<room_id>/<author>/<msg_id>/<key>  Reaction marker
      bans/<room_id>/<banned>                                Ban marker (creator only)
      mutes/<muted>                                          Mute marker (the viewer's own list)
      tags/<hash_id>                                         PubkyAppTag (Nexus discovery)
      profile.json                                           local nickname

  `parse/1` turns a path (from a listing or an event) into a tagged tuple and
  rejects anything that does not match the strict per-segment rules, so
  untrusted paths never reach the rest of the app unvalidated.
  """

  alias PubkyRooms.Ids

  @ns "/pub/pubky-rooms/"
  @reaction_re ~r/^[a-z0-9_]{1,16}$/
  @tag_re ~r/^[0-9A-HJKMNP-TV-Z]{26}$/

  @type room_ref :: {creator :: String.t(), room_id :: String.t()}
  @type parsed ::
          {:room, String.t()}
          | {:member, String.t(), String.t()}
          | {:message, String.t(), String.t(), String.t()}
          | {:reaction, String.t(), String.t(), String.t(), String.t(), String.t()}
          | {:ban, String.t(), String.t()}
          | {:mute, String.t()}
          | {:tag, String.t()}
          | :profile
          | :ignore

  @doc "The namespace prefix every Pubky Rooms path starts with."
  @spec namespace() :: String.t()
  def namespace, do: @ns

  def rooms_dir, do: @ns <> "rooms/"
  def members_dir, do: @ns <> "members/"
  def messages_dir({creator, room_id}), do: @ns <> "messages/#{creator}/#{room_id}/"
  def reactions_dir({creator, room_id}), do: @ns <> "reactions/#{creator}/#{room_id}/"
  def bans_dir(room_id), do: @ns <> "bans/#{room_id}/"
  def mutes_dir, do: @ns <> "mutes/"
  def tags_dir, do: @ns <> "tags/"

  def room(room_id), do: @ns <> "rooms/#{room_id}"
  def member({creator, room_id}), do: @ns <> "members/#{creator}/#{room_id}"
  def message({creator, room_id}, msg_id), do: @ns <> "messages/#{creator}/#{room_id}/#{msg_id}"

  def reaction({creator, room_id}, author, msg_id, key),
    do: @ns <> "reactions/#{creator}/#{room_id}/#{author}/#{msg_id}/#{key}"

  def ban(room_id, banned), do: @ns <> "bans/#{room_id}/#{banned}"
  def mute(muted), do: @ns <> "mutes/#{muted}"
  def tag(id), do: @ns <> "tags/#{id}"
  def profile, do: @ns <> "profile.json"

  @doc "The canonical `pubky://` URI of a room."
  @spec room_uri(room_ref()) :: String.t()
  def room_uri({creator, room_id}), do: "pubky://#{creator}#{room(room_id)}"

  @doc "The canonical `pubky://` URI of a message."
  @spec message_uri(String.t(), room_ref(), String.t()) :: String.t()
  def message_uri(author, ref, msg_id), do: "pubky://#{author}#{message(ref, msg_id)}"

  @doc "Parses a room URI into its ref."
  @spec parse_room_uri(term()) :: {:ok, room_ref()} | :error
  def parse_room_uri("pubky://" <> rest) do
    with [creator, path] <- String.split(rest, "/", parts: 2),
         {:room, id} <- parse("/" <> path),
         true <- Ids.valid_z32?(creator) do
      {:ok, {creator, id}}
    else
      _ -> :error
    end
  end

  def parse_room_uri(_), do: :error

  @doc "Parses a message URI into `{author, room_ref, msg_id}`."
  @spec parse_message_uri(term()) :: {:ok, {String.t(), room_ref(), String.t()}} | :error
  def parse_message_uri("pubky://" <> rest) do
    with [author, path] <- String.split(rest, "/", parts: 2),
         {:message, creator, id, msg_id} <- parse("/" <> path),
         true <- Ids.valid_z32?(author) do
      {:ok, {author, {creator, id}, msg_id}}
    else
      _ -> :error
    end
  end

  def parse_message_uri(_), do: :error

  @doc "Classifies a homeserver path. Anything outside the namespace or malformed is `:ignore`."
  @spec parse(term()) :: parsed()
  def parse(@ns <> rest), do: rest |> String.split("/") |> classify()
  def parse(_), do: :ignore

  defp classify(["rooms", id]), do: if(Ids.valid_id?(id), do: {:room, id}, else: :ignore)

  defp classify(["members", creator, id]),
    do:
      if(Ids.valid_z32?(creator) and Ids.valid_id?(id), do: {:member, creator, id}, else: :ignore)

  defp classify(["messages", creator, id, msg_id]) do
    if Ids.valid_z32?(creator) and Ids.valid_id?(id) and Ids.valid_id?(msg_id),
      do: {:message, creator, id, msg_id},
      else: :ignore
  end

  defp classify(["reactions", creator, id, author, msg_id, key]) do
    if Ids.valid_z32?(creator) and Ids.valid_id?(id) and Ids.valid_z32?(author) and
         Ids.valid_id?(msg_id) and Regex.match?(@reaction_re, key),
       do: {:reaction, creator, id, author, msg_id, key},
       else: :ignore
  end

  defp classify(["bans", id, banned]),
    do: if(Ids.valid_id?(id) and Ids.valid_z32?(banned), do: {:ban, id, banned}, else: :ignore)

  defp classify(["mutes", muted]),
    do: if(Ids.valid_z32?(muted), do: {:mute, muted}, else: :ignore)

  defp classify(["tags", id]), do: if(Regex.match?(@tag_re, id), do: {:tag, id}, else: :ignore)
  defp classify(["profile.json"]), do: :profile
  defp classify(_), do: :ignore
end

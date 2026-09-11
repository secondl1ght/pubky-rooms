defmodule PubkyRooms.Rooms.Membership do
  @moduledoc """
  Join markers (`members/<creator>/<room_id>` on the member's homeserver).

      {"v":1,"joined_at":1757600000000,"room":"pubky://<creator>/pub/pubky-rooms/rooms/<room_id>"}

  The `room` field must match the path; markers whose body disagrees with
  their location are ignored.
  """

  alias PubkyRooms.Rooms.{Paths, Room}

  @doc "Encodes a join marker for the room."
  @spec encode(Paths.room_ref()) :: binary()
  def encode(ref),
    do: JSON.encode!(%{v: 1, joined_at: System.os_time(:millisecond), room: Paths.room_uri(ref)})

  @doc "Decodes a join marker and checks it refers to `ref`."
  @spec decode(binary(), Paths.room_ref()) ::
          {:ok, %{joined_at: non_neg_integer()}} | {:error, term()}
  def decode(bytes, ref) when is_binary(bytes) do
    with :ok <- Room.size_ok(bytes),
         {:ok, %{"v" => 1} = map} <- Room.decode_json(bytes),
         {:ok, ^ref} <- Paths.parse_room_uri(map["room"]) || {:error, :room_mismatch},
         {:ok, joined_at} <- Room.timestamp(map["joined_at"]) do
      {:ok, %{joined_at: joined_at}}
    else
      {:ok, _} -> {:error, :room_mismatch}
      :error -> {:error, :room_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end
end

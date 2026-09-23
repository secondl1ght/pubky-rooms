defmodule PubkyRooms.Rooms.Ban do
  @moduledoc """
  Ban markers (`bans/<room_id>/<banned_z32>` on the *creator's* homeserver).

      {"v":1,"created_at":1757600000000,"reason":"spam"}

  A ban is honored only when the marker lives on the room creator's
  homeserver (the path owner is checked against the room ref). While banned,
  a member's messages and reactions are hidden from the room and they cannot
  post; deleting the marker lifts the ban. The reason (≤ 140 characters) is
  shown to the banned member and to the creator.
  """

  alias PubkyRooms.Rooms.Room

  @reason_max 140

  @type t :: %{created_at: non_neg_integer(), reason: String.t() | nil}

  @doc "Maximum reason length."
  def reason_max, do: @reason_max

  @doc "Validates an optional reason: trimmed, printable, at most #{@reason_max} characters."
  @spec validate_reason(term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def validate_reason(reason) do
    case Room.blank_to_nil(reason) do
      nil ->
        {:ok, nil}

      text ->
        cond do
          String.length(text) > @reason_max ->
            {:error, "Reasons can be up to #{@reason_max} characters."}

          not Room.printable?(text) ->
            {:error, "The reason contains unsupported characters."}

          true ->
            {:ok, text}
        end
    end
  end

  @doc "Encodes a ban marker."
  @spec encode(String.t() | nil) :: binary()
  def encode(reason),
    do: JSON.encode!(%{v: 1, created_at: System.os_time(:millisecond), reason: reason})

  @doc "Decodes a ban marker read from the creator's homeserver."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    with :ok <- Room.size_ok(bytes),
         {:ok, %{"v" => 1} = map} <- Room.decode_json(bytes),
         {:ok, created_at} <- Room.timestamp(map["created_at"]),
         {:ok, reason} <- validate_reason(map["reason"]) do
      {:ok, %{created_at: created_at, reason: reason}}
    else
      {:ok, _other} -> {:error, :unsupported_version}
      {:error, reason} -> {:error, reason}
    end
  end
end

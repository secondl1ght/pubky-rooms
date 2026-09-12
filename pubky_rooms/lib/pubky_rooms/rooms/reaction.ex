defmodule PubkyRooms.Rooms.Reaction do
  @moduledoc """
  Reaction markers (`reactions/<creator>/<room_id>/<author>/<msg_id>/<key>` on
  the *reactor's* homeserver).

      {"v":1,"created_at":1757600000000}

  Everything that matters is in the path: who reacted (the path owner), to
  which message, with which key. The body is never fetched; a `PUT` event adds
  the reaction, a `DEL` event removes it, and a directory listing at bootstrap
  restores them. Keys are `^[a-z0-9_]{1,16}$`; this client writes the v1
  palette only and renders unknown keys as text.
  """

  @palette [
    {"up", "👍"},
    {"heart", "❤️"},
    {"laugh", "😂"},
    {"eyes", "👀"},
    {"fire", "🔥"},
    {"sad", "😢"}
  ]

  @keys Enum.map(@palette, &elem(&1, 0))

  @doc "The reaction keys this client offers, in display order, with their emoji."
  @spec palette() :: [{String.t(), String.t()}]
  def palette, do: @palette

  @doc "Whether the key is one this client writes."
  @spec writable?(term()) :: boolean()
  def writable?(key), do: key in @keys

  @doc "The emoji for a key, or the key itself for ones outside the palette."
  @spec emoji(String.t()) :: String.t()
  def emoji(key), do: :proplists.get_value(key, @palette, key)

  @doc "Encodes a reaction marker."
  @spec encode() :: binary()
  def encode, do: JSON.encode!(%{v: 1, created_at: System.os_time(:millisecond)})
end

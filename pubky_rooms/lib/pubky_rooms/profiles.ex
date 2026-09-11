defmodule PubkyRooms.Profiles do
  @moduledoc """
  Display names and avatars for public keys.

  Milestone 5 adds the Pubky App profile lookup and cache; for now every user
  is shown by a shortened key.
  """

  @type profile :: %{pubky: String.t(), name: String.t(), avatar_url: String.t() | nil}

  @doc "The profile to display for a public key."
  @spec get(String.t()) :: profile()
  def get(z32), do: %{pubky: z32, name: short_key(z32), avatar_url: nil}

  @doc "A short, recognizable form of a public key (`ABCD…WXYZ`)."
  @spec short_key(String.t()) :: String.t()
  def short_key(z32) when byte_size(z32) > 8,
    do: String.upcase(String.slice(z32, 0, 4)) <> "…" <> String.upcase(String.slice(z32, -4, 4))

  def short_key(z32), do: z32
end

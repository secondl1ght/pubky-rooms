defmodule PubkyRooms.Profiles.LocalProfile do
  @moduledoc """
  The Rooms nickname file, `/pub/pubky-rooms/profile.json`:

      {"v":1,"name":"satoshi"}

  Used as the display name when the user has no Pubky App profile. Names are
  1 to 32 characters after trimming, with control characters removed.
  """

  alias PubkyRooms.Rooms.Room

  @name_max 32

  @doc "The maximum nickname length."
  def name_max, do: @name_max

  @doc "Validates a nickname; returns the cleaned name or an error message."
  @spec validate(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(name) when is_binary(name) do
    name = name |> String.replace(~r/[\p{C}]/u, "") |> String.trim()

    cond do
      name == "" -> {:error, "Enter a name."}
      String.length(name) > @name_max -> {:error, "Names can be up to #{@name_max} characters."}
      true -> {:ok, name}
    end
  end

  def validate(_), do: {:error, "Enter a name."}

  @doc "Encodes the nickname file."
  @spec encode(String.t()) :: binary()
  def encode(name), do: JSON.encode!(%{v: 1, name: name})

  @doc "Decodes and validates a nickname file."
  @spec decode(binary()) :: {:ok, %{name: String.t()}} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    with :ok <- Room.size_ok(bytes),
         {:ok, %{"v" => 1} = map} <- Room.decode_json(bytes),
         {:ok, name} <- validate(map["name"]) do
      {:ok, %{name: name}}
    else
      {:ok, _} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end
end

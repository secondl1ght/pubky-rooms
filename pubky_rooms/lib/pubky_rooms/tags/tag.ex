defmodule PubkyRooms.Tags.Tag do
  @moduledoc """
  Universal tags (`tags/<hash id>` in the Pubky Rooms namespace), the
  pubky-app-specs `PubkyAppTag` shape:

      {"uri":"pubky://<creator>/pub/pubky-rooms/rooms/<room_id>","label":"bitcoin","created_at":1757600000000000}

  The id is the Crockford base32 of the first 16 bytes of
  `blake3("<uri>:<label>")`, so one user can tag one URI with one label
  exactly once and the file can be found without listing. Labels are trimmed
  and lowercased, 1 to 20 characters. Nexus indexes these under the
  `pubky-rooms` app namespace (ADR 0003); Rooms itself only cares about tags
  whose URI is a room.
  """

  alias Pubky.Crypto.Blake3
  alias PubkyRooms.Ids
  alias PubkyRooms.Rooms.{Paths, Room}

  @label_max 20
  @auto_label "room"
  @max_custom_labels 4

  @type t :: %{
          uri: String.t(),
          label: String.t(),
          created_at: non_neg_integer(),
          # Unix microseconds, as pubky-app-specs writes it
          room_ref: Paths.room_ref() | nil
        }

  @doc "Maximum label length."
  def label_max, do: @label_max

  @doc "The label every public room gets automatically."
  def auto_label, do: @auto_label

  @doc "How many labels a creator may add to a room at creation (besides `room`)."
  def max_custom_labels, do: @max_custom_labels

  # pubky-app-specs `validationLimits.tagInvalidChars`: a tag is one word.
  # The `TagInput` hook strips the same characters as the user types.
  @banned [",", ":", " ", "\t", "\n", "\r"]

  @doc "Characters a label may not contain (pubky-app-specs `tagInvalidChars`)."
  def banned_chars, do: @banned

  @doc """
  Normalizes a label the way pubky-app-specs does: trimmed and lowercased,
  1..#{@label_max} characters, one word (no comma, colon or whitespace).
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(label) when is_binary(label) do
    normalized = label |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:error, "Enter a tag."}

      String.length(normalized) > @label_max ->
        {:error, "Tags can be up to #{@label_max} characters."}

      not Room.printable?(normalized) ->
        {:error, "The tag contains unsupported characters."}

      String.contains?(normalized, @banned) ->
        {:error, "Tags are one word: no spaces, commas or colons."}

      true ->
        {:ok, normalized}
    end
  end

  def normalize(_), do: {:error, "Enter a tag."}

  @doc """
  Suggestions for a partially typed label, as Pubky App's tag input offers
  them: known labels containing `query` (case-insensitive), never the exact
  match or an excluded label, at most `limit`, in the order given.

      iex> Tag.suggest(["bitcoin", "bitkit", "music"], "bit", [], 5)
      ["bitcoin", "bitkit"]
  """
  @spec suggest([String.t()], String.t() | nil, [String.t()], pos_integer()) :: [String.t()]
  def suggest(known, query, exclude \\ [], limit \\ 5)
  def suggest(_known, nil, _exclude, _limit), do: []

  def suggest(known, query, exclude, limit) when is_binary(query) do
    q = query |> String.trim() |> String.downcase()

    if q == "" do
      []
    else
      known
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()
      |> Enum.filter(&(String.contains?(&1, q) and &1 != q and &1 not in exclude))
      |> Enum.take(limit)
    end
  end

  @doc """
  Parses a comma- or space-separated list of labels typed by a user into at
  most `max` unique normalized labels (the automatic label is dropped).
  """
  @spec parse_labels(term(), pos_integer()) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse_labels(input, max \\ @max_custom_labels)
  def parse_labels(nil, _max), do: {:ok, []}

  def parse_labels(input, max) when is_binary(input) do
    parts = input |> String.replace("#", " ") |> String.split(~r/[\s,]+/, trim: true)

    with {:ok, labels} <- normalize_all(parts) do
      labels = labels |> Enum.uniq() |> Enum.reject(&(&1 == @auto_label))

      if length(labels) > max,
        do: {:error, "Add up to #{max} tags."},
        else: {:ok, labels}
    end
  end

  def parse_labels(_, _max), do: {:error, "Enter tags as words separated by spaces or commas."}

  defp normalize_all(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case normalize(part) do
        {:ok, label} -> {:cont, {:ok, acc ++ [label]}}
        {:error, reason} -> {:halt, {:error, "“#{String.slice(part, 0, 24)}” #{reason}"}}
      end
    end)
  end

  @doc "The hash id of a tag: Crockford base32 of the first 16 bytes of blake3(`uri:label`)."
  @spec id(String.t(), String.t()) :: String.t()
  def id(uri, label),
    do: "#{uri}:#{label}" |> Blake3.hash() |> binary_part(0, 16) |> Ids.crockford()

  @doc "The homeserver path of the tag `label` on `uri`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(uri, label), do: Paths.tag(id(uri, label))

  @doc "Encodes a tag file."
  @spec encode(String.t(), String.t()) :: binary()
  def encode(uri, label),
    do: JSON.encode!(%{uri: uri, label: label, created_at: System.os_time(:microsecond)})

  @doc """
  Decodes a tag file read from `owner`'s homeserver at `path` and checks that
  the id matches its content. `room_ref` is set when the URI is a room.
  """
  @spec decode(binary(), String.t()) :: {:ok, t()} | {:error, term()}
  def decode(bytes, path) when is_binary(bytes) do
    with :ok <- Room.size_ok(bytes),
         {:ok, map} <- Room.decode_json(bytes),
         uri when is_binary(uri) and byte_size(uri) <= 300 <-
           map["uri"] || {:error, :invalid_uri},
         {:ok, label} <- normalize(map["label"]),
         true <- map["label"] == label || {:error, :label_not_normalized},
         {:tag, id} <- Paths.parse(path),
         true <- id == id(uri, label) || {:error, :id_mismatch},
         {:ok, created_at} <- Room.timestamp(map["created_at"]) do
      room_ref =
        case Paths.parse_room_uri(uri) do
          {:ok, ref} -> ref
          :error -> nil
        end

      {:ok, %{uri: uri, label: label, created_at: created_at, room_ref: room_ref}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_tag}
    end
  end
end

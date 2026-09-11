defmodule PubkyRooms.Rooms.Room do
  @moduledoc """
  A room definition (`rooms/<room_id>` on the creator's homeserver).

      {"v":1,"name":"Bitcoin devs","topic":"…","visibility":"public","created_at":1757600000000}

  The creator is never stored in the file: it is the owner of the path.
  Timestamps are Unix milliseconds.
  """

  alias PubkyRooms.Ids
  alias PubkyRooms.Rooms.Paths

  @name_max 64
  @topic_max 280
  @max_bytes 16_384
  @visibilities ~w(public unlisted)

  @type t :: %__MODULE__{
          creator: String.t(),
          id: String.t(),
          name: String.t(),
          topic: String.t() | nil,
          visibility: String.t(),
          created_at: non_neg_integer()
        }

  @enforce_keys [:creator, :id, :name, :visibility, :created_at]
  defstruct [:creator, :id, :name, :topic, :visibility, :created_at]

  @doc "Maximum name length."
  def name_max, do: @name_max
  @doc "Maximum topic length."
  def topic_max, do: @topic_max

  @doc "The room's `{creator, id}` reference."
  @spec ref(t()) :: Paths.room_ref()
  def ref(%__MODULE__{creator: c, id: id}), do: {c, id}

  @doc "The room's `pubky://` URI."
  @spec uri(t()) :: String.t()
  def uri(room), do: Paths.room_uri(ref(room))

  @doc """
  Validates user input for a new or updated room. Returns the cleaned fields or
  a keyword list of `{field, {message, opts}}` errors usable with `to_form/2`.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, keyword()}
  def validate(attrs) when is_map(attrs) do
    name = attrs |> field("name") |> to_string() |> String.trim()
    topic = attrs |> field("topic") |> blank_to_nil()
    visibility = attrs |> field("visibility") |> to_string()

    errors =
      []
      |> check(String.length(name) in 1..@name_max, :name, "must be 1 to #{@name_max} characters")
      |> check(printable?(name), :name, "contains invalid characters")
      |> check(
        is_nil(topic) or String.length(topic) <= @topic_max,
        :topic,
        "must be at most #{@topic_max} characters"
      )
      |> check(is_nil(topic) or printable?(topic), :topic, "contains invalid characters")
      |> check(visibility in @visibilities, :visibility, "must be public or unlisted")

    if errors == [],
      do: {:ok, %{name: name, topic: topic, visibility: visibility}},
      else: {:error, Enum.reverse(errors)}
  end

  @doc "Builds a new room for `creator` from validated attributes."
  @spec new(String.t(), map()) :: {:ok, t()} | {:error, keyword()}
  def new(creator, attrs) do
    with {:ok, fields} <- validate(attrs) do
      {:ok,
       %__MODULE__{
         creator: creator,
         id: Ids.next(),
         name: fields.name,
         topic: fields.topic,
         visibility: fields.visibility,
         created_at: System.os_time(:millisecond)
       }}
    end
  end

  @doc "Encodes the room definition as JSON."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = room) do
    JSON.encode!(%{
      v: 1,
      name: room.name,
      topic: room.topic,
      visibility: room.visibility,
      created_at: room.created_at
    })
  end

  @doc "Decodes and validates a room definition read from `creator`'s homeserver."
  @spec decode(binary(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def decode(bytes, creator, id) when is_binary(bytes) do
    with :ok <- size_ok(bytes),
         {:ok, %{"v" => 1} = map} <- decode_json(bytes),
         {:ok, fields} <- validate(map),
         {:ok, created_at} <- timestamp(map["created_at"]) do
      {:ok,
       %__MODULE__{
         creator: creator,
         id: id,
         name: fields.name,
         topic: fields.topic,
         visibility: fields.visibility,
         created_at: created_at
       }}
    else
      {:ok, _other} -> {:error, :unsupported_version}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def decode_json(bytes) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc false
  def size_ok(bytes) when byte_size(bytes) <= @max_bytes, do: :ok
  def size_ok(_), do: {:error, :too_large}

  @doc false
  def timestamp(ms) when is_integer(ms) and ms >= 0, do: {:ok, ms}
  def timestamp(_), do: {:error, :invalid_timestamp}

  @doc false
  def field(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  @doc false
  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc false
  def printable?(string), do: String.printable?(string) and not String.contains?(string, <<0>>)

  @doc false
  def check(errors, true, _field, _msg), do: errors
  def check(errors, false, field, msg), do: [{field, {msg, []}} | errors]
end

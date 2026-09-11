defmodule PubkyRooms.Rooms.Message do
  @moduledoc """
  A chat message (`messages/<creator>/<room_id>/<msg_id>` on the author's
  homeserver).

      {"v":1,"kind":"text","content":"gm","reply_to":null,"created_at":1757600000000,"edited_at":null}

  The author is the owner of the path. In memory a message also carries its
  delivery `state`:

    * `:confirmed` — read from, or announced by, the author's homeserver
    * `:pending` — written by this node, homeserver event not seen yet
    * `:failed` — the write failed (`fail_reason` says why)
  """

  alias PubkyRooms.Ids
  alias PubkyRooms.Rooms.{Paths, Room}

  @content_max 2000
  @kinds ~w(text)

  @type key :: {msg_id :: String.t(), author :: String.t()}
  @type state :: :confirmed | :pending | :failed

  @type t :: %__MODULE__{
          key: key(),
          msg_id: String.t(),
          author: String.t(),
          room_ref: Paths.room_ref(),
          kind: String.t(),
          content: String.t(),
          reply_to: String.t() | nil,
          created_at: non_neg_integer(),
          edited_at: non_neg_integer() | nil,
          state: state(),
          fail_reason: term(),
          uri: String.t(),
          reactions: map()
        }

  @enforce_keys [:key, :msg_id, :author, :room_ref, :content, :created_at, :uri]
  defstruct [
    :key,
    :msg_id,
    :author,
    :room_ref,
    :content,
    :reply_to,
    :created_at,
    :edited_at,
    :fail_reason,
    :uri,
    kind: "text",
    state: :confirmed,
    reactions: %{}
  ]

  @doc "Maximum content length in characters."
  def content_max, do: @content_max

  @doc "Validates message text: trimmed, non-blank, printable, at most #{@content_max} characters."
  @spec validate_content(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_content(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:error, "can't be blank"}

      String.length(trimmed) > @content_max ->
        {:error, "must be at most #{@content_max} characters"}

      not Room.printable?(trimmed) ->
        {:error, "contains invalid characters"}

      true ->
        {:ok, trimmed}
    end
  end

  def validate_content(_), do: {:error, "can't be blank"}

  @doc "Builds a new pending message by `author` in `room_ref`."
  @spec new(String.t(), Paths.room_ref(), String.t(), keyword()) ::
          {:ok, t()} | {:error, String.t()}
  def new(author, room_ref, content, opts \\ []) do
    with {:ok, content} <- validate_content(content),
         {:ok, reply_to} <- validate_reply_to(opts[:reply_to], room_ref) do
      msg_id = Ids.next()

      {:ok,
       %__MODULE__{
         key: {msg_id, author},
         msg_id: msg_id,
         author: author,
         room_ref: room_ref,
         content: content,
         reply_to: reply_to,
         created_at: System.os_time(:millisecond),
         state: :pending,
         uri: Paths.message_uri(author, room_ref, msg_id)
       }}
    end
  end

  @doc "The homeserver path of the message."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{room_ref: ref, msg_id: id}), do: Paths.message(ref, id)

  @doc "Encodes the message as JSON (the bytes that go to the homeserver)."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = m) do
    JSON.encode!(%{
      v: 1,
      kind: m.kind,
      content: m.content,
      reply_to: m.reply_to,
      created_at: m.created_at,
      edited_at: m.edited_at
    })
  end

  @doc "Decodes and validates a message read from `author`'s homeserver."
  @spec decode(binary(), String.t(), Paths.room_ref(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def decode(bytes, author, room_ref, msg_id) when is_binary(bytes) do
    with :ok <- Room.size_ok(bytes),
         {:ok, %{"v" => 1} = map} <- Room.decode_json(bytes),
         true <- map["kind"] in @kinds || {:error, :unsupported_kind},
         {:ok, content} <- validate_content(map["content"]),
         {:ok, reply_to} <- validate_reply_to(map["reply_to"], room_ref),
         {:ok, created_at} <- Room.timestamp(map["created_at"]),
         {:ok, edited_at} <- optional_timestamp(map["edited_at"]) do
      {:ok,
       %__MODULE__{
         key: {msg_id, author},
         msg_id: msg_id,
         author: author,
         room_ref: room_ref,
         kind: map["kind"],
         content: content,
         reply_to: reply_to,
         created_at: created_at,
         edited_at: edited_at,
         state: :confirmed,
         uri: Paths.message_uri(author, room_ref, msg_id)
       }}
    else
      {:ok, _other} -> {:error, :unsupported_version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_reply_to(nil, _ref), do: {:ok, nil}

  defp validate_reply_to(uri, ref) when is_binary(uri) do
    case Paths.parse_message_uri(uri) do
      {:ok, {_author, ^ref, _msg_id}} -> {:ok, uri}
      _ -> {:error, :invalid_reply_to}
    end
  end

  defp validate_reply_to(_, _), do: {:error, :invalid_reply_to}

  defp optional_timestamp(nil), do: {:ok, nil}
  defp optional_timestamp(ms), do: Room.timestamp(ms)
end

defmodule Pubky.Events.SSE do
  @moduledoc """
  An incremental Server-Sent Events parser (WHATWG EventSource framing).

  Feed it raw chunks as they arrive; it returns complete frames and keeps any
  partial trailing line buffered. Lines may end in `\\n` or `\\r\\n`; comment
  lines (starting with `:`) are dropped but still count as activity for
  keep-alive purposes.

  A line longer than #{64 * 1024} bytes, or a frame whose `data` grows past
  that, is a protocol error (`{:error, :frame_too_large}`): a homeserver
  cannot make this parser buffer without bound.
  """

  @max_bytes 64 * 1024

  @type frame :: %{event: String.t(), data: String.t(), id: String.t() | nil}
  @type t :: %__MODULE__{
          buffer: binary(),
          event: String.t() | nil,
          data: [String.t()],
          data_bytes: non_neg_integer(),
          id: String.t() | nil
        }

  defstruct buffer: "", event: nil, data: [], data_bytes: 0, id: nil

  @doc "A fresh parser."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The largest line or frame data accepted, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Feeds a chunk; returns the frames completed by it and the updated parser,
  or `{:error, :frame_too_large}` when the input exceeds `max_bytes/0`.
  """
  @spec feed(t(), binary()) :: {[frame()], t()} | {:error, :frame_too_large}
  def feed(%__MODULE__{buffer: buffer} = parser, chunk) do
    {lines, rest} = split_lines(buffer <> chunk)

    if byte_size(rest) > @max_bytes do
      {:error, :frame_too_large}
    else
      case parse_lines(lines, %{parser | buffer: ""}) do
        {:error, _} = error -> error
        {frames, parser} -> {Enum.reverse(frames), %{parser | buffer: rest}}
      end
    end
  end

  defp parse_lines(lines, parser) do
    Enum.reduce_while(lines, {[], parser}, fn line, acc ->
      case line(line, acc) do
        {:error, _} = error -> {:halt, error}
        acc -> {:cont, acc}
      end
    end)
  end

  # Splits complete lines off the buffer, keeping an incomplete tail (and a
  # dangling "\r" that may be the first half of a CRLF).
  defp split_lines(bin) do
    parts = String.split(bin, "\n")
    {complete, [tail]} = Enum.split(parts, -1)
    {Enum.map(complete, &String.trim_trailing(&1, "\r")), tail}
  end

  defp line("", {frames, parser}), do: dispatch(frames, parser)
  defp line(":" <> _comment, acc), do: acc
  defp line(line, _acc) when byte_size(line) > @max_bytes, do: {:error, :frame_too_large}

  defp line(line, {frames, parser}) do
    {field, value} =
      case String.split(line, ":", parts: 2) do
        [field, " " <> value] -> {field, value}
        [field, value] -> {field, value}
        [field] -> {field, ""}
      end

    case field do
      "data" ->
        bytes = parser.data_bytes + byte_size(value)

        if bytes > @max_bytes,
          do: {:error, :frame_too_large},
          else: {frames, %{parser | data: [value | parser.data], data_bytes: bytes}}

      "event" ->
        {frames, %{parser | event: value}}

      "id" ->
        {frames, %{parser | id: value}}

      _ ->
        {frames, parser}
    end
  end

  defp dispatch(frames, %{data: []} = parser), do: {frames, %{parser | event: nil, id: nil}}

  defp dispatch(frames, parser) do
    frame = %{
      event: parser.event || "message",
      data: parser.data |> Enum.reverse() |> Enum.join("\n"),
      id: parser.id
    }

    {[frame | frames], %{parser | event: nil, data: [], data_bytes: 0, id: nil}}
  end
end

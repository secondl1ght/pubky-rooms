defmodule Pubky.Events.SSE do
  @moduledoc """
  An incremental Server-Sent Events parser (WHATWG EventSource framing).

  Feed it raw chunks as they arrive; it returns complete frames and keeps any
  partial trailing line buffered. Lines may end in `\\n` or `\\r\\n`; comment
  lines (starting with `:`) are dropped but still count as activity for
  keep-alive purposes.
  """

  @type frame :: %{event: String.t(), data: String.t(), id: String.t() | nil}
  @type t :: %__MODULE__{
          buffer: binary(),
          event: String.t() | nil,
          data: [String.t()],
          id: String.t() | nil
        }

  defstruct buffer: "", event: nil, data: [], id: nil

  @doc "A fresh parser."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Feeds a chunk; returns the frames completed by it and the updated parser."
  @spec feed(t(), binary()) :: {[frame()], t()}
  def feed(%__MODULE__{buffer: buffer} = parser, chunk) do
    {lines, rest} = split_lines(buffer <> chunk)
    {frames, parser} = Enum.reduce(lines, {[], %{parser | buffer: ""}}, &line/2)
    {Enum.reverse(frames), %{parser | buffer: rest}}
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

  defp line(line, {frames, parser}) do
    {field, value} =
      case String.split(line, ":", parts: 2) do
        [field, " " <> value] -> {field, value}
        [field, value] -> {field, value}
        [field] -> {field, ""}
      end

    parser =
      case field do
        "event" -> %{parser | event: value}
        "data" -> %{parser | data: [value | parser.data]}
        "id" -> %{parser | id: value}
        _ -> parser
      end

    {frames, parser}
  end

  defp dispatch(frames, %{data: []} = parser), do: {frames, %{parser | event: nil, id: nil}}

  defp dispatch(frames, parser) do
    frame = %{
      event: parser.event || "message",
      data: parser.data |> Enum.reverse() |> Enum.join("\n"),
      id: parser.id
    }

    {[frame | frames], %{parser | event: nil, data: [], id: nil}}
  end
end

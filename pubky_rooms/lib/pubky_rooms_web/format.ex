defmodule PubkyRoomsWeb.Format do
  @moduledoc "Small formatting helpers for templates."

  @doc "A compact relative time (`just now`, `5m`, `3h`, `2d`, or a date) for a Unix-ms timestamp."
  @spec relative(non_neg_integer() | nil, non_neg_integer()) :: String.t()
  def relative(ms, now_ms \\ System.os_time(:millisecond))
  def relative(nil, _now), do: ""

  def relative(ms, now) when is_integer(ms) do
    seconds = div(now - ms, 1000)

    cond do
      seconds < 45 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      seconds < 7 * 86_400 -> "#{div(seconds, 86_400)}d"
      true -> ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%b %-d")
    end
  end

  @doc "Cuts text to at most `max` characters (on a single line), adding an ellipsis when cut."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, max) when is_binary(text) do
    flat = text |> String.split(~r/\s+/) |> Enum.join(" ")

    if String.length(flat) > max,
      do: String.slice(flat, 0, max - 1) <> "…",
      else: flat
  end

  @doc "Time of day (`14:05`) for a Unix-ms timestamp, in UTC."
  @spec clock(non_neg_integer()) :: String.t()
  def clock(ms), do: ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M")

  @doc "An ISO 8601 string for `<time datetime>` attributes."
  @spec iso(non_neg_integer()) :: String.t()
  def iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end

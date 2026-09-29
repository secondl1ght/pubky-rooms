defmodule PubkyRoomsWeb.JSCommandsTest do
  use ExUnit.Case, async: true

  # `JS.show`/`JS.toggle` write an inline `display: block` unless told otherwise,
  # which silently breaks any flex or grid element (dialogs, toasts and the
  # reaction palette all shipped stacked this way). Every call states its display.
  test "every JS.show and JS.toggle names the display it reveals with" do
    offenders =
      "lib/**/*.{ex,heex}"
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        source = File.read!(file)

        ~r/JS\.(show|toggle)\(/
        |> Regex.scan(source, return: :index)
        |> Enum.map(fn [{start, len} | _] -> call_at(source, start + len) end)
        |> Enum.reject(&String.contains?(&1, "display:"))
        |> Enum.map(&"#{file}: #{String.slice(&1, 0, 60)}")
      end)

    assert offenders == [], "JS.show/JS.toggle without display: #{inspect(offenders)}"
  end

  # the text of the call from just after its opening paren to the matching one
  # (`from` is a byte offset from Regex.scan, so slice bytes, not graphemes)
  defp call_at(source, from) do
    source
    |> binary_part(from, byte_size(source) - from)
    |> String.graphemes()
    |> Enum.reduce_while({1, []}, fn
      "(", {depth, acc} -> {:cont, {depth + 1, ["(" | acc]}}
      ")", {1, acc} -> {:halt, {0, acc}}
      ")", {depth, acc} -> {:cont, {depth - 1, [")" | acc]}}
      ch, {depth, acc} -> {:cont, {depth, [ch | acc]}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end
end

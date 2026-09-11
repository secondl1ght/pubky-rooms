defmodule PubkyRooms.Tags.Color do
  @moduledoc """
  Deterministic tag colors, compatible with Pubky App.

  Pubky App colors a tag chip from its label alone, so the same label looks the
  same in every client. This module reproduces that mapping exactly (including
  the JavaScript 32-bit integer semantics of the hash), so a `#bitcoin` or
  `#music` chip in Pubky Rooms matches the one in Pubky App.

  Special brand labels have fixed colors; every other label hashes to one of six
  `FF00xx`-style patterns.
  """

  import Bitwise

  @custom %{
    "bitcoin" => "#FF9900",
    "synonym" => "#FF6600",
    "bitkit" => "#FF4400",
    "pubky" => "#C8FF00",
    "blocktank" => "#FFAE00",
    "tether" => "#26A17B"
  }

  @doc """
  Returns the hex color (`"#RRGGBB"`) for a label.

      iex> PubkyRooms.Tags.Color.hex("bitcoin")
      "#FF9900"
      iex> PubkyRooms.Tags.Color.hex("test")
      "#0092FF"
  """
  @spec hex(String.t()) :: String.t()
  def hex(label) when is_binary(label) do
    case Map.fetch(@custom, String.downcase(label)) do
      {:ok, color} ->
        color

      :error ->
        positive = label |> js_hash() |> abs()
        byte = positive &&& 0xFF
        hx = byte |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")

        pattern =
          case rem(positive, 6) do
            0 -> "FF00" <> hx
            1 -> "FF" <> hx <> "00"
            2 -> hx <> "FF00"
            3 -> hx <> "00FF"
            4 -> "00" <> hx <> "FF"
            5 -> "00FF" <> hx
          end

        "#" <> pattern
    end
  end

  @doc "Returns the color as an `{r, g, b}` tuple."
  @spec rgb(String.t()) :: {0..255, 0..255, 0..255}
  def rgb(label) do
    <<"#", r::binary-size(2), g::binary-size(2), b::binary-size(2)>> = hex(label)
    {String.to_integer(r, 16), String.to_integer(g, 16), String.to_integer(b, 16)}
  end

  @doc """
  Returns the color as a space-separated `"r g b"` triple, suitable for a CSS
  custom property consumed as `rgb(var(--tag-rgb) / 0.3)`.
  """
  @spec css_rgb(String.t()) :: String.t()
  def css_rgb(label) do
    {r, g, b} = rgb(label)
    "#{r} #{g} #{b}"
  end

  # `Array.from(str).reduce((h, ch) => ch.charCodeAt(0) + ((h << 5) - h), 0)`
  # `<<` operates on the value coerced to a signed 32-bit integer; the `-` and
  # `+` are exact (the magnitudes stay far below 2^53).
  defp js_hash(label) do
    label
    |> String.to_charlist()
    |> Enum.map(&first_utf16_unit/1)
    |> Enum.reduce(0, fn code, h -> code + (to_int32(to_int32(h) <<< 5) - h) end)
  end

  # `charCodeAt(0)` on an astral code point yields its high surrogate.
  defp first_utf16_unit(cp) when cp > 0xFFFF, do: 0xD800 + ((cp - 0x10000) >>> 10)
  defp first_utf16_unit(cp), do: cp

  defp to_int32(n) do
    <<signed::signed-32>> = <<n::32>>
    signed
  end
end

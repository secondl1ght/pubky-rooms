defmodule PubkyRoomsWeb.IconsTest do
  use ExUnit.Case, async: true

  @icons Path.expand("../../deps/lucide/icons", __DIR__)

  # A `lucide-<name>` class only exists when the SVG is in the vendored set;
  # a misspelt or renamed icon renders as nothing (two hover buttons shipped
  # empty this way).
  test "every lucide-* icon named in the app exists in the vendored set" do
    names =
      "lib/**/*.{ex,heex}"
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        ~r/lucide-([a-z0-9]+(?:-[a-z0-9]+)*)/
        |> Regex.scan(File.read!(file))
        |> Enum.map(fn [_, name] -> name end)
      end)
      |> Enum.uniq()

    assert length(names) > 20
    missing = Enum.reject(names, &File.exists?(Path.join(@icons, &1 <> ".svg")))
    assert missing == [], "icons missing from deps/lucide: #{inspect(missing)}"
  end
end

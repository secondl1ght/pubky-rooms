defmodule PubkyRoomsWeb.UI.BadgeTest do
  use PubkyRoomsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PubkyRoomsWeb.UI.Badge

  defp badge(variant) do
    render_component(&Badge.badge/1,
      variant: variant,
      inner_block: [%{inner_block: fn _, _ -> "x" end}]
    )
  end

  test "the outline and soft variants keep their border colour" do
    # a transparent default in the base class used to win over these (CSS order)
    for {variant, border} <- [
          {"outline", "border-border"},
          {"brand-soft", "border-brand/40"},
          {"destructive-soft", "border-destructive/40"}
        ] do
      html = badge(variant)
      assert html =~ border, variant
      refute html =~ "border-transparent", variant
    end
  end

  test "filled variants hide their border" do
    for variant <- ["default", "secondary", "brand", "destructive"] do
      assert badge(variant) =~ "border-transparent", variant
    end
  end
end

defmodule PubkyRoomsWeb.UI.TagInputTest do
  use PubkyRoomsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PubkyRoomsWeb.UI.{Form, Tag, TagInput}

  test "renders chips with an x, the add control, the hidden field and suggestions" do
    html =
      render_component(&TagInput.tag_input/1,
        id: "t",
        name: "room[tags]",
        labels: ["bitcoin", "dev"],
        suggestions: ["bitkit"],
        max: 4
      )

    assert html =~ ~s(phx-hook="TagInput")
    assert html =~ ~s(data-on-add="add_tag")
    assert html =~ ~s(data-count="2")
    assert html =~ ~s(data-max="4")
    assert html =~ ~s(name="room[tags]" value="bitcoin dev")
    assert html =~ ~s(aria-label="Remove bitcoin")
    assert html =~ ~s(data-role="add")
    assert html =~ ~s(data-role="field" hidden)
    assert html =~ ~s(data-role="suggestion" data-label="bitkit")
    refute html =~ ~r/data-role="add"[^>]*\sdisabled[\s>]/
  end

  test "at the limit the add button is disabled" do
    html = render_component(&TagInput.tag_input/1, id: "t", labels: ["a", "b"], max: 2)
    assert html =~ ~r/data-role="add"[^>]*disabled/
  end

  test "disabled shows the chips only" do
    html = render_component(&TagInput.tag_input/1, id: "t", labels: ["a"], disabled: true)
    refute html =~ "data-role"
    refute html =~ "Remove a"
    assert html =~ ">a<"
  end

  test "a removable chip keeps the label colour and carries the remove event" do
    html = render_component(&Tag.tag/1, label: "bitcoin", removable: true, on_remove: "drop")
    assert html =~ "--tag-rgb: 255 153 0"
    assert html =~ ~s(phx-click="drop")
    assert html =~ ~s(phx-value-label="bitcoin")
  end

  test "choice cards render a radio per option with the current one checked" do
    field = %Phoenix.HTML.FormField{
      id: "room_visibility",
      name: "room[visibility]",
      value: "unlisted",
      errors: [],
      field: :visibility,
      form: nil
    }

    html =
      render_component(&Form.choice_cards/1,
        field: field,
        label: "Visibility",
        options: [
          %{value: "public", title: "Public", description: "Listed", icon: "lucide-globe"},
          %{value: "unlisted", title: "Unlisted", description: "Link only", icon: "lucide-link"}
        ]
      )

    assert html =~ ~s(type="radio" name="room[visibility]" value="public")
    assert html =~ ~r/value="unlisted"[^>]*checked/
    refute html =~ ~r/value="public"[^>]*checked/
    assert html =~ "peer-checked:border-brand"
  end
end

defmodule PubkyRoomsWeb.UI.Tag do
  @moduledoc """
  Colored tag chips, identical in look to Pubky App tags.

  The chip color is derived from the label by `PubkyRooms.Tags.Color`, so a
  label is the same color everywhere in the Pubky ecosystem.
  """
  use Phoenix.Component

  alias PubkyRooms.Tags.Color

  @doc """
  Renders a tag chip. Pass `phx-click` (and friends) to make it interactive.

      <.tag label="bitcoin" count={12} />
      <.tag label="music" selected phx-click="toggle" phx-value-label="music" />
  """
  attr :label, :string, required: true
  attr :count, :integer, default: nil
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled aria-pressed href navigate patch)

  def tag(assigns) do
    assigns = assign(assigns, :style, "--tag-rgb: #{Color.css_rgb(assigns.label)}")

    ~H"""
    <button
      type="button"
      style={@style}
      class={[
        "flex h-8 w-fit max-w-full cursor-pointer items-center rounded-md border px-3 text-sm font-bold",
        "transition-all duration-200 bg-[rgb(var(--tag-rgb)/0.3)]",
        "hover:shadow-[inset_0_0_10px_2px_rgb(var(--tag-rgb)/0.5)]",
        (@selected && "border-[rgb(var(--tag-rgb)/0.5)]") || "border-transparent",
        @class
      ]}
      aria-pressed={@selected}
      {@rest}
    >
      <span class="truncate">{@label}</span>
      <span :if={@count} class="ml-1.5 font-medium text-foreground/50">{@count}</span>
    </button>
    """
  end
end

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
  attr :size, :string, default: "default", values: ~w(default sm)

  attr :static, :boolean,
    default: false,
    doc: "render a non-interactive span (e.g. inside a link)"

  attr :removable, :boolean,
    default: false,
    doc: "a chosen tag with an x inside the chip; `on_remove` receives `phx-value-label`"

  attr :on_remove, :any, default: nil, doc: "event name or `JS` for the x"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled aria-pressed href navigate patch)

  def tag(%{removable: true} = assigns) do
    assigns =
      assigns
      |> assign(:style, "--tag-rgb: #{Color.css_rgb(assigns.label)}")
      |> assign(:classes, [
        "flex w-fit max-w-full items-center gap-1 rounded-md border border-transparent font-bold",
        (assigns.size == "sm" && "h-6 pr-1 pl-2 text-xs") || "h-8 pr-1.5 pl-3 text-sm",
        "bg-[rgb(var(--tag-rgb)/0.3)]",
        assigns.class
      ])

    ~H"""
    <span style={@style} class={@classes} {@rest}>
      <span class="truncate">{@label}</span>
      <button
        type="button"
        phx-click={@on_remove}
        phx-value-label={@label}
        class="flex size-4 shrink-0 cursor-pointer items-center justify-center rounded opacity-70 transition-opacity hover:opacity-100"
        aria-label={"Remove #{@label}"}
      >
        <span class="lucide-x size-3" aria-hidden="true" />
      </button>
    </span>
    """
  end

  def tag(assigns) do
    assigns =
      assigns
      |> assign(:style, "--tag-rgb: #{Color.css_rgb(assigns.label)}")
      |> assign(:classes, [
        "flex w-fit max-w-full items-center rounded-md border font-bold",
        (assigns.size == "sm" && "h-6 px-2 text-xs") || "h-8 px-3 text-sm",
        "transition-all duration-200 bg-[rgb(var(--tag-rgb)/0.3)]",
        (assigns.selected && "border-[rgb(var(--tag-rgb)/0.5)]") || "border-transparent",
        assigns.class
      ])

    ~H"""
    <span :if={@static} style={@style} class={@classes} {@rest}>
      <span class="truncate">{@label}</span>
      <span :if={@count} class="ml-1.5 font-medium text-foreground/50">{@count}</span>
    </span>
    <button
      :if={!@static}
      type="button"
      style={@style}
      class={[
        @classes,
        "cursor-pointer hover:shadow-[inset_0_0_10px_2px_rgb(var(--tag-rgb)/0.5)]",
        "disabled:cursor-default disabled:hover:shadow-none"
      ]}
      aria-pressed={to_string(@selected)}
      {@rest}
    >
      <span class="truncate">{@label}</span>
      <span :if={@count} class="ml-1.5 font-medium text-foreground/50">{@count}</span>
    </button>
    """
  end
end

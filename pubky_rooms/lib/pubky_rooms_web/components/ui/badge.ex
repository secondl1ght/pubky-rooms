defmodule PubkyRoomsWeb.UI.Badge do
  @moduledoc "Small rounded labels for counts and statuses."
  use Phoenix.Component

  # Every variant names its own border colour: the base class only sets the
  # border width, because a `border-transparent` default in the base would win
  # over the variant's colour (Tailwind orders both utilities alphabetically).
  @variants %{
    "default" => "bg-primary text-primary-foreground border-transparent",
    "secondary" => "bg-secondary text-secondary-foreground border-transparent",
    "brand" => "bg-brand text-background border-transparent",
    "brand-soft" => "bg-brand/16 text-brand border-brand/40",
    "destructive" => "bg-destructive text-white border-transparent",
    "destructive-soft" => "bg-destructive/16 text-destructive border-destructive/40",
    "outline" => "border-border text-foreground"
  }

  @doc """
  Renders a badge.

      <.badge>12</.badge>
      <.badge variant="brand-soft"><.icon name="lucide-radio" class="size-3" /> live</.badge>
  """
  attr :variant, :string, default: "default", values: Map.keys(@variants)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    assigns = assign(assigns, :variant_classes, @variants[assigns.variant])

    ~H"""
    <span
      class={[
        "inline-flex w-fit items-center justify-center gap-1 whitespace-nowrap rounded-md border",
        "px-2 py-0.5 text-xs font-medium",
        @variant_classes,
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end
end

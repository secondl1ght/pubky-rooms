defmodule PubkyRoomsWeb.UI.Badge do
  @moduledoc "Small rounded labels for counts and statuses."
  use Phoenix.Component

  @variants %{
    "default" => "bg-primary text-primary-foreground",
    "secondary" => "bg-secondary text-secondary-foreground",
    "brand" => "bg-brand text-background",
    "brand-soft" => "bg-brand/16 text-brand border-brand/40",
    "destructive" => "bg-destructive text-white",
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
        "inline-flex w-fit items-center justify-center gap-1 whitespace-nowrap rounded-md border border-transparent",
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

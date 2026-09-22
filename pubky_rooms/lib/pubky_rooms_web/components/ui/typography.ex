defmodule PubkyRoomsWeb.UI.Typography do
  @moduledoc """
  The Pubky type scale as a component.

  Sizes: `xs`, `sm`, `md` (medium weight) and `lg`, `xl`, `2xl` (bold headings).
  """
  use Phoenix.Component

  @sizes %{
    "xs" => "text-xs font-medium",
    "sm" => "text-sm font-medium",
    "md" => "text-base font-medium",
    "lg" => "text-2xl font-bold leading-tight tracking-tight",
    "xl" => "text-4xl font-bold leading-tight tracking-tight",
    "2xl" => "text-6xl font-bold leading-none tracking-tight"
  }

  @doc """
  Renders text at a scale step.

      <.typography size="xl" tag="h1">Sign in to <span class="text-brand">Rooms</span>.</.typography>
      <.typography size="sm" class="text-muted-foreground">Rooms live on your homeserver.</.typography>
  """
  attr :size, :string, default: "md", values: Map.keys(@sizes)
  attr :tag, :string, default: "p"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def typography(assigns) do
    assigns = assign(assigns, :size_classes, @sizes[assigns.size])

    ~H"""
    <.dynamic_tag tag_name={@tag} class={[@size_classes, @class]} {@rest}>
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  @doc """
  A section title: 24px, weight 300, in the foreground colour. Hierarchy comes
  from colour as well as size: titles are white, the supporting text under
  them is muted. Pass `text-muted-foreground` to de-emphasise a group (the
  lobby's collapsed "Closed" archives do).
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def section_title(assigns) do
    ~H"""
    <h2 class={["text-2xl font-light text-foreground", @class]} {@rest}>
      {render_slot(@inner_block)}
    </h2>
    """
  end
end

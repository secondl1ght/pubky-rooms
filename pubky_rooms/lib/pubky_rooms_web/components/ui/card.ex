defmodule PubkyRoomsWeb.UI.Card do
  @moduledoc """
  Cards: the dark `#1D1D20` surfaces that hold nearly all content.

  Variants: `default` (`rounded-xl`, vertical padding) and `post` (`rounded-md`,
  no vertical padding; sections carry their own padding), matching feed cards.
  """
  use Phoenix.Component

  @variants %{
    "default" => "rounded-xl py-6",
    "post" => "rounded-md py-0",
    "flat" => "rounded-md py-0 shadow-none"
  }

  @doc """
  Renders a card.

      <.card>
        <.card_header>
          <.card_title>Room name</.card_title>
          <.card_description>What this room is about</.card_description>
        </.card_header>
        <.card_content>…</.card_content>
        <.card_footer>…</.card_footer>
      </.card>
  """
  attr :variant, :string, default: "default", values: Map.keys(@variants)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    assigns = assign(assigns, :variant_classes, @variants[assigns.variant])

    ~H"""
    <div
      class={["flex flex-col gap-6 bg-card text-card-foreground shadow-sm", @variant_classes, @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_header(assigns) do
    ~H"""
    <div class={["grid gap-1.5 px-6", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_title(assigns) do
    ~H"""
    <h3 class={["text-lg font-bold leading-tight", @class]} {@rest}>{render_slot(@inner_block)}</h3>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_description(assigns) do
    ~H"""
    <p class={["text-sm text-muted-foreground", @class]} {@rest}>{render_slot(@inner_block)}</p>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_content(assigns) do
    ~H"""
    <div class={["px-6", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card_footer(assigns) do
    ~H"""
    <div class={["flex items-center px-6", @class]} {@rest}>{render_slot(@inner_block)}</div>
    """
  end
end

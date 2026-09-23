defmodule PubkyRoomsWeb.UI.Button do
  @moduledoc """
  Pill buttons in the Pubky App variants.

  Renders a `<button>`, or a `<.link>` when `href`, `navigate` or `patch` is
  given. Variants:

    * `default` — lime tint with lime text and border (the standard action)
    * `brand` — solid lime with dark text (the strongest call to action)
    * `secondary` — neutral grey pill
    * `ghost` — borderless, hover tint only
    * `outline` — translucent with a grey border
    * `destructive` / `destructive-soft` — red actions
    * `link` — text only, underlined on hover
    * `dark` / `dark-outline` — near-black variants for use over images
  """
  use Phoenix.Component

  @variants %{
    "default" => "bg-brand/16 text-brand border-brand hover:bg-brand/30",
    "brand" =>
      "bg-brand text-background border-brand hover:bg-brand-hover hover:border-brand-hover",
    "secondary" =>
      "bg-secondary text-secondary-foreground border-secondary hover:bg-accent hover:border-accent",
    "ghost" => "border-transparent shadow-none hover:bg-accent/50 hover:text-accent-foreground",
    "outline" => "bg-input/30 border-input hover:bg-input/50",
    "destructive" =>
      "bg-destructive/60 text-destructive-foreground border-transparent hover:bg-destructive/90",
    "destructive-soft" =>
      "bg-destructive/16 text-destructive border-destructive hover:bg-destructive/30",
    "link" => "border-transparent shadow-none text-primary underline-offset-4 hover:underline",
    "dark" => "bg-neutral-900 text-white border-neutral-900 hover:bg-neutral-800",
    "dark-outline" => "bg-transparent border-neutral-700 hover:bg-neutral-800 hover:text-white"
  }

  @sizes %{
    "default" => "h-10 px-4 py-2 gap-1",
    "sm" => "h-8 px-3 gap-1.5",
    "lg" => "h-auto px-8 py-5 text-sm font-bold",
    "icon" => "size-9 p-0",
    "icon-lg" => "size-12 p-0",
    "tab" => "h-12 px-5 gap-2"
  }

  @base "inline-flex items-center justify-center gap-2 whitespace-nowrap text-sm font-semibold rounded-full border " <>
          "shadow-xs transition-all cursor-pointer outline-none select-none " <>
          "disabled:opacity-50 disabled:pointer-events-none aria-disabled:opacity-50 aria-disabled:pointer-events-none " <>
          "focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:border-ring"

  @doc """
  Renders a button.

      <.button phx-click="send">Send</.button>
      <.button variant="brand" size="lg" navigate={~p"/rooms/new"}>Create room</.button>
      <.button variant="secondary" size="icon" aria-label="Settings">
        <.icon name="lucide-settings" />
      </.button>
  """
  attr :variant, :string, default: "default", values: Map.keys(@variants)
  attr :size, :string, default: "default", values: Map.keys(@sizes)
  attr :type, :string, default: "button"
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(href navigate patch method download name value disabled form aria-label aria-pressed replace)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        @base,
        @variants[assigns.variant],
        @sizes[assigns.size],
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button type={@type} class={@classes} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  The floating action button: a large translucent circle fixed above the
  mobile tab bar (bottom-right on desktop) that turns lime on hover.

      <.fab navigate={~p"/rooms/new"} label="Open a room" />
  """
  attr :label, :string, required: true
  attr :icon, :string, default: "lucide-plus"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch)

  def fab(assigns) do
    ~H"""
    <.link
      aria-label={@label}
      data-tip={@label}
      class={[
        "tooltip fixed right-3 bottom-18 z-40 flex size-20 items-center justify-center rounded-full",
        "bg-white/12 text-white shadow-xl backdrop-blur-lg transition-colors hover:bg-brand hover:text-background",
        "sm:right-10 md:bottom-20 lg:bottom-6",
        @class
      ]}
      {@rest}
    >
      <span class={[@icon, "size-10"]} aria-hidden="true" />
    </.link>
    """
  end

  @doc "Classes shared by every button; exposed for the rare element that must look like one."
  @spec button_classes(String.t(), String.t()) :: [String.t()]
  def button_classes(variant \\ "default", size \\ "default"),
    do: [@base, @variants[variant], @sizes[size]]
end

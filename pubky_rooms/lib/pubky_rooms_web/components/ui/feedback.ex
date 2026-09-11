defmodule PubkyRoomsWeb.UI.Feedback do
  @moduledoc """
  Feedback components: flash toasts, spinners, skeletons and empty states.
  """
  use Phoenix.Component
  use Gettext, backend: PubkyRoomsWeb.Gettext

  import PubkyRoomsWeb.UI.Transitions

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash toast (bottom-right dark card, as Pubky App's toasts).

      <.flash kind={:info} flash={@flash} />
      <.flash id="offline" kind={:error} title="Offline" hidden>Reconnecting…</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error, :success], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "pointer-events-auto flex w-80 items-start gap-3 rounded-xl border bg-card p-4 text-sm shadow-lg sm:w-96",
        @kind == :error && "border-destructive/40",
        @kind == :success && "border-brand/40"
      ]}
      {@rest}
    >
      <span
        class={[
          "mt-0.5 size-5 shrink-0",
          @kind == :info && "lucide-info text-secondary-foreground",
          @kind == :success && "lucide-circle-check text-brand",
          @kind == :error && "lucide-circle-alert text-destructive"
        ]}
        aria-hidden="true"
      />
      <div class="flex min-w-0 flex-1 flex-col gap-0.5">
        <p :if={@title} class="font-bold leading-tight">{@title}</p>
        <p class="text-secondary-foreground">{msg}</p>
      </div>
      <button
        type="button"
        class="group cursor-pointer self-start text-muted-foreground hover:text-foreground"
        aria-label={gettext("close")}
      >
        <span class="lucide-x size-4" aria-hidden="true" />
      </button>
    </div>
    """
  end

  @doc "A spinning ring."
  attr :class, :any, default: "size-5"
  attr :rest, :global

  def spinner(assigns) do
    ~H"""
    <span
      class={[
        "inline-block animate-spin rounded-full border-2 border-muted-foreground/30 border-t-brand",
        @class
      ]}
      role="status"
      aria-label="Loading"
      {@rest}
    />
    """
  end

  @doc "A pulsing placeholder block."
  attr :class, :any, default: nil
  attr :rest, :global

  def skeleton(assigns) do
    ~H"""
    <div class={["animate-pulse-soft rounded-md bg-accent/50", @class]} {@rest} />
    """
  end

  @doc """
  An empty state with icon, title, description and optional actions.

      <.empty_state icon="lucide-messages-square" title="No rooms yet">
        Create one to get started.
        <:actions><.button variant="brand" navigate={~p"/rooms/new"}>Create room</.button></:actions>
      </.empty_state>
  """
  attr :icon, :string, default: "lucide-sparkles"
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "flex flex-col items-center justify-center gap-3 rounded-xl bg-card px-6 py-12 text-center",
      @class
    ]}>
      <span class="flex size-14 items-center justify-center rounded-full bg-brand/16 text-brand">
        <span class={[@icon, "size-7"]} aria-hidden="true" />
      </span>
      <h3 class="text-lg font-bold">{@title}</h3>
      <p :if={@inner_block != []} class="max-w-sm text-sm text-muted-foreground">
        {render_slot(@inner_block)}
      </p>
      <div :if={@actions != []} class="mt-2 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end
end

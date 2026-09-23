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

  Success and info toasts dismiss themselves after `dismiss_after`
  milliseconds (the `AutoDismiss` hook; paused while hovered or focused);
  error toasts stay until clicked, so nothing that needs acting on fades away.

      <.flash kind={:info} flash={@flash} />
      <.flash id="offline" kind={:error} title="Offline" hidden>Reconnecting…</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error, :success], doc: "used for styling and flash lookup"

  attr :dismiss_after, :integer,
    default: nil,
    doc: "ms before the toast dismisses itself; default 5000 for info/success, never for errors"

  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns =
      assigns
      |> assign_new(:id, fn -> "flash-#{assigns.kind}" end)
      |> assign_new(:auto_dismiss, fn
        %{dismiss_after: ms} when is_integer(ms) -> ms
        %{kind: kind} when kind in [:info, :success] -> 5000
        _ -> nil
      end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook={@auto_dismiss && "AutoDismiss"}
      data-dismiss-after={@auto_dismiss}
      role="alert"
      class={[
        "pointer-events-auto flex w-full items-start gap-3 rounded-xl border bg-card p-4 text-sm shadow-lg sm:w-96",
        @kind == :error && "border-destructive/40",
        @kind == :success && "border-brand/40"
      ]}
      {@rest}
    >
      <span
        class={[
          "size-5 shrink-0",
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
        class="group flex size-5 shrink-0 cursor-pointer items-center justify-center self-start text-muted-foreground hover:text-foreground"
        aria-label={gettext("close")}
      >
        <span class="lucide-x size-4" aria-hidden="true" />
      </button>
    </div>
    """
  end

  @doc """
  The live indicator: a brand-lime dot with a slow ring breathing outwards,
  used wherever the UI says "n online". The ring is still under
  `prefers-reduced-motion`. Decorative: pair it with visible text.

      <.live_dot /> {@online} online
  """
  attr :class, :any, default: "size-2"
  attr :rest, :global

  def live_dot(assigns) do
    ~H"""
    <span class={["relative inline-flex shrink-0", @class]} aria-hidden="true" {@rest}>
      <span class="absolute inset-0 rounded-full bg-brand motion-safe:animate-live-ping"></span>
      <span class="relative size-full rounded-full bg-brand"></span>
    </span>
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

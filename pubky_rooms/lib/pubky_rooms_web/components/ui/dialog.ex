defmodule PubkyRoomsWeb.UI.Dialog do
  @moduledoc """
  Modal dialogs. On small screens the panel slides up as a bottom sheet; from
  the `sm` breakpoint it is centered and zooms in, as in Pubky App.

  The dialog is hidden by default and toggled client-side with
  `show_dialog/2` / `hide_dialog/2`, or opened on mount with `show`.
  `on_cancel` runs when the user presses Escape, clicks the backdrop or the
  close button — typically a `JS.patch` back to the parent route.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders a dialog.

      <.dialog id="new-room" show on_cancel={JS.patch(~p"/")}>
        <:title>New room</:title>
        <:description>Rooms live on your homeserver.</:description>
        <.form …>…</.form>
        <:footer>
          <.button variant="ghost" phx-click={hide_dialog("new-room")}>Cancel</.button>
          <.button variant="brand" type="submit" form="room-form">Create</.button>
        </:footer>
      </.dialog>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :class, :any, default: nil, doc: "extra classes for the panel"

  attr :labelled_by, :string,
    default: nil,
    doc: "id of a heading rendered in the body, when the title slot is not used"

  attr :described_by, :string, default: nil, doc: "id of a description rendered in the body"
  slot :title
  slot :description
  slot :inner_block, required: true
  slot :footer

  def dialog(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_dialog(@id)}
      phx-remove={hide_dialog(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div
        id={"#{@id}-bg"}
        class="fixed inset-0 bg-background/70 backdrop-blur-sm"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={@labelled_by || "#{@id}-title"}
        aria-describedby={@described_by || "#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-end justify-center sm:items-center sm:p-4">
          <.focus_wrap
            id={"#{@id}-container"}
            phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
            phx-key="escape"
            phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
            class={[
              "relative flex w-full max-h-[calc(100dvh-2rem)] flex-col gap-6 overflow-x-hidden overflow-y-auto border border-b-0",
              "bg-background p-6 shadow-lg rounded-t-xl",
              "sm:w-auto sm:min-w-[28rem] sm:max-w-[calc(100vw-2rem)] sm:rounded-xl sm:border-b sm:p-8",
              @class
            ]}
          >
            <button
              type="button"
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              class="absolute right-4 top-4 flex size-9 cursor-pointer items-center justify-center rounded-full text-muted-foreground transition-colors hover:bg-accent/50 hover:text-foreground"
              aria-label="Close"
            >
              <span class="lucide-x size-5" aria-hidden="true" />
            </button>
            <div :if={@title != [] or @description != []} class="flex flex-col gap-1.5 pr-8">
              <h2 :if={@title != []} id={"#{@id}-title"} class="text-2xl font-bold leading-tight">
                {render_slot(@title)}
              </h2>
              <p
                :if={@description != []}
                id={"#{@id}-description"}
                class="text-sm text-muted-foreground"
              >
                {render_slot(@description)}
              </p>
            </div>
            <div class="flex flex-col gap-4">{render_slot(@inner_block)}</div>
            <div :if={@footer != []} class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
              {render_slot(@footer)}
            </div>
          </.focus_wrap>
        </div>
      </div>
    </div>
    """
  end

  @doc "Shows the dialog with the given id."
  @spec show_dialog(JS.t(), String.t()) :: JS.t()
  def show_dialog(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 200,
      transition: {"transition-opacity ease-out duration-200", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-container",
      # the panel is a flex column; JS.show would otherwise set display: block
      display: "flex",
      time: 250,
      transition:
        {"transition-all ease-out duration-250",
         "opacity-0 translate-y-full sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-container")
  end

  @doc "Hides the dialog with the given id."
  @spec hide_dialog(JS.t(), String.t()) :: JS.t()
  def hide_dialog(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      time: 200,
      transition: {"transition-opacity ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> JS.hide(
      to: "##{id}-container",
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-full sm:translate-y-0 sm:scale-95"}
    )
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"}, time: 200)
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end
end

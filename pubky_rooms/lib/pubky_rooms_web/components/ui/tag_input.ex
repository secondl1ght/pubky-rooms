defmodule PubkyRoomsWeb.UI.TagInput do
  @moduledoc """
  The tag input, behaving like Pubky App's: the chosen labels as coloured chips
  (each with an x to remove it), then a small "+" that turns into an inline
  field. Typing is lowercased and stripped of the spec's banned characters as
  you go, Enter adds, Backspace on an empty field removes the last chip, Escape
  or leaving the empty field folds it back to "+", and up to five matching
  known labels are offered underneath. At the limit the field is disabled and
  reads "limit reached".

  The labels live in the LiveView; the `TagInput` hook only drives the field
  and pushes three events, named through the attrs: `on_add` with `%{"label"
  => label}`, `on_remove` with `%{"label" => label}` and `on_query` with
  `%{"q" => text}` (answer it by assigning `suggestions`). With `name` set, a
  hidden input carries the labels space-separated so the surrounding form
  still receives them.

      <.tag_input id="room-tags" name="room[tags]" labels={@tag_labels}
        suggestions={@tag_suggestions} max={4} />
  """
  use Phoenix.Component

  import PubkyRoomsWeb.UI.Icon
  import PubkyRoomsWeb.UI.Tag

  alias PubkyRooms.Tags.Tag, as: Rules

  attr :id, :string, required: true
  attr :name, :string, default: nil, doc: "hidden field name; the labels are joined with spaces"
  attr :labels, :list, default: [], doc: "the chosen labels, in order"
  attr :suggestions, :list, default: [], doc: "labels to offer under the field"
  attr :max, :integer, default: nil, doc: "how many labels may be chosen"
  attr :on_add, :string, default: "add_tag"
  attr :on_remove, :string, default: "remove_tag"
  attr :on_query, :string, default: "tag_query"
  attr :placeholder, :string, default: "add tag"
  attr :size, :string, default: "default", values: ~w(default sm)
  attr :disabled, :boolean, default: false, doc: "show the chips only"
  attr :class, :any, default: nil

  def tag_input(assigns) do
    assigns =
      assign(assigns, :at_limit, assigns.max != nil and length(assigns.labels) >= assigns.max)

    ~H"""
    <div
      id={@id}
      class={["flex flex-wrap items-center gap-1.5", @class]}
      phx-hook="TagInput"
      data-on-add={@on_add}
      data-on-remove={@on_remove}
      data-on-query={@on_query}
      data-count={length(@labels)}
      data-max={@max}
    >
      <input :if={@name} type="hidden" name={@name} value={Enum.join(@labels, " ")} />
      <.tag
        :for={label <- @labels}
        label={label}
        size={@size}
        removable={!@disabled}
        on_remove={@on_remove}
        data-label={label}
      />
      <div :if={!@disabled} class="relative" data-role="control">
        <button
          type="button"
          data-role="add"
          class={[
            "flex items-center justify-center rounded-md border border-dashed border-input text-foreground/40 transition-colors",
            "hover:border-foreground/40 hover:text-foreground/70 disabled:cursor-not-allowed disabled:opacity-50",
            (@size == "sm" && "size-6") || "size-8"
          ]}
          disabled={@at_limit}
          aria-label="Add a tag"
        >
          <.icon name="lucide-plus" class={(@size == "sm" && "size-3.5") || "size-4"} />
        </button>
        <div
          data-role="field"
          hidden
          class={[
            "flex items-center rounded-md border border-dashed border-input pr-1 pl-3 shadow-xs",
            (@size == "sm" && "h-6 w-36") || "h-8 w-40"
          ]}
        >
          <input
            id={"#{@id}-input"}
            type="text"
            phx-update="ignore"
            maxlength={Rules.label_max()}
            placeholder={@placeholder}
            data-placeholder={@placeholder}
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            class={[
              "h-full w-full min-w-0 bg-transparent font-bold text-foreground caret-foreground outline-none",
              "placeholder:font-bold placeholder:text-input [&.at-limit]:placeholder:text-destructive",
              "disabled:opacity-100",
              (@size == "sm" && "text-xs") || "text-sm"
            ]}
            aria-label="New tag"
          />
          <button
            type="button"
            data-role="close"
            class="ml-1 flex size-5 shrink-0 items-center justify-center rounded-full text-muted-foreground hover:text-foreground"
            aria-label="Stop adding tags"
          >
            <.icon name="lucide-x" class="size-3.5" />
          </button>
        </div>
        <ul
          :if={@suggestions != []}
          data-role="suggestions"
          role="listbox"
          class="absolute top-full left-0 z-20 mt-1 min-w-40 overflow-hidden rounded-md border border-border bg-popover shadow-lg"
        >
          <li :for={label <- @suggestions} role="option">
            <button
              type="button"
              phx-click={@on_add}
              phx-value-label={label}
              data-role="suggestion"
              data-label={label}
              class="w-full cursor-pointer px-3 py-2 text-left text-sm font-medium text-popover-foreground hover:bg-accent aria-selected:bg-accent"
            >
              {label}
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end

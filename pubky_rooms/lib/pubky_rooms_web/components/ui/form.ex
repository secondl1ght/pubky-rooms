defmodule PubkyRoomsWeb.UI.Form do
  @moduledoc """
  Form controls: inputs, textareas, selects, checkboxes, labels and errors.

  `input/1` accepts a `Phoenix.HTML.FormField` (from `<.form for={@form}>`) or
  explicit `name`/`value` and renders the matching control with the Pubky look
  (transparent field, grey border, lime-less focus ring).
  """
  use Phoenix.Component
  use Gettext, backend: PubkyRoomsWeb.Gettext

  import PubkyRoomsWeb.UI.Icon

  alias Phoenix.HTML.Form, as: HTMLForm

  @input_base "flex w-full min-w-0 rounded-md border border-input bg-transparent text-base shadow-xs outline-none " <>
                "placeholder:text-muted-foreground md:text-sm " <>
                "focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 " <>
                "disabled:cursor-not-allowed disabled:opacity-50 " <>
                "aria-invalid:border-destructive aria-invalid:ring-destructive/20"

  @doc """
  Renders an input with label and errors.

      <.input field={@form[:name]} label="Room name" />
      <.input field={@form[:topic]} type="textarea" label="Topic" rows="3" />
      <.input field={@form[:visibility]} type="select" options={[Listed: "public", Unlisted: "unlisted"]} />
      <.input field={@form[:agree]} type="checkbox" label="I agree" />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox email hidden number password search select tel text textarea url)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to HTMLForm.options_for_select/2"
  attr :multiple, :boolean, default: false
  attr :variant, :string, default: "default", values: ~w(default inline), doc: "textarea style"
  attr :class, :any, default: nil, doc: "extra classes for the control"
  attr :wrapper_class, :any, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete autofocus cols disabled form list max maxlength min minlength
                pattern placeholder readonly required rows size step spellcheck)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        HTMLForm.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class={["flex flex-col gap-1.5", @wrapper_class]}>
      <label class="flex cursor-pointer items-center gap-2 text-sm">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <span class="relative flex size-4 shrink-0 items-center justify-center">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={[
              "peer size-4 cursor-pointer appearance-none rounded-xs border border-input bg-transparent shadow-xs outline-none",
              "checked:border-brand checked:bg-brand focus-visible:ring-[3px] focus-visible:ring-ring/50",
              @class
            ]}
            {@rest}
          />
          <span
            class="lucide-check pointer-events-none absolute hidden size-3 text-background peer-checked:block"
            aria-hidden="true"
          />
        </span>
        <span :if={@label}>{@label}</span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class={["flex flex-col gap-1.5", @wrapper_class]}>
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class={[input_base(), "h-9 px-3 py-1", @errors != [] && "border-destructive", @class]}
        multiple={@multiple}
        aria-invalid={@errors != []}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {HTMLForm.options_for_select(@options, @value)}
      </select>
      <p :if={@hint} class="text-xs text-muted-foreground">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class={["flex flex-col gap-1.5", @wrapper_class]}>
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "flex w-full rounded-md bg-transparent text-base outline-none placeholder:text-muted-foreground md:text-sm",
          @variant == "default" &&
            "min-h-16 border border-input px-3 py-2 shadow-xs focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:opacity-50",
          @variant == "inline" &&
            "min-h-6 resize-none border-none p-0 font-medium text-secondary-foreground",
          @errors != [] && "border-destructive",
          @class
        ]}
        aria-invalid={@errors != []}
        {@rest}
      >{HTMLForm.normalize_value("textarea", @value)}</textarea>
      <p :if={@hint} class="text-xs text-muted-foreground">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1.5", @wrapper_class]}>
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={HTMLForm.normalize_value(@type, @value)}
        class={[input_base(), "h-9 px-3 py-1", @errors != [] && "border-destructive", @class]}
        aria-invalid={@errors != []}
        {@rest}
      />
      <p :if={@hint} class="text-xs text-muted-foreground">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  defp input_base, do: @input_base

  @doc """
  A radio group rendered as selectable cards, for a choice between a few
  options that each deserve a sentence (room visibility, for example). The
  checked card gets the brand outline.

      <.choice_cards field={@form[:visibility]} label="Visibility" options={[
        %{value: "public", title: "Listed", description: "…", icon: "lucide-globe"},
        %{value: "unlisted", title: "Unlisted", description: "…", icon: "lucide-link"}
      ]} />
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: nil
  attr :options, :list, required: true, doc: "maps with `value`, `title`, `description`, `icon`"
  attr :class, :any, default: nil

  def choice_cards(assigns) do
    ~H"""
    <fieldset class={["flex flex-col gap-1.5", @class]}>
      <legend :if={@label} class="mb-1.5 text-sm font-semibold leading-none text-secondary-foreground">
        {@label}
      </legend>
      <div class="grid gap-2 sm:grid-cols-2">
        <label :for={opt <- @options} class="cursor-pointer">
          <input
            type="radio"
            name={@field.name}
            value={opt.value}
            checked={to_string(@field.value) == opt.value}
            class="peer sr-only"
          />
          <span class={[
            "flex h-full items-start gap-3 rounded-md border border-input/60 p-3 transition-colors",
            "hover:bg-white/[0.03] peer-checked:border-brand peer-checked:bg-brand/10",
            "peer-focus-visible:ring-[3px] peer-focus-visible:ring-ring/50"
          ]}>
            <.icon name={opt.icon} class="mt-0.5 size-4 shrink-0 text-brand" />
            <span class="flex flex-col gap-0.5">
              <span class="text-sm font-semibold text-foreground">{opt.title}</span>
              <span class="text-xs text-muted-foreground">{opt.description}</span>
            </span>
          </span>
        </label>
      </div>
    </fieldset>
    """
  end

  @doc "Renders a field label."
  attr :for, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class={["text-sm font-semibold leading-none text-secondary-foreground", @class]}>
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc "Renders a field error message."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="flex items-center gap-1.5 text-sm text-destructive">
      <span class="lucide-circle-alert size-4 shrink-0" aria-hidden="true" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "Translates an error message using gettext."
  @spec translate_error({String.t(), keyword()}) :: String.t()
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(PubkyRoomsWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PubkyRoomsWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  @spec translate_errors(keyword(), atom()) :: [String.t()]
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end

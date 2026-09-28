defmodule PubkyRoomsWeb.UI.Transitions do
  @moduledoc """
  Shared `Phoenix.LiveView.JS` transitions used by the component library.
  """

  alias Phoenix.LiveView.JS

  @doc """
  Fades an element in (opacity + slight lift). Pass `display:` when the element
  is not laid out as a block: `JS.show` writes an inline `display` and would
  turn a flex row into a stack (the connection toasts lost their layout that
  way until 2026-09-28).
  """
  @spec show(String.t()) :: JS.t()
  def show(selector) when is_binary(selector), do: show(%JS{}, selector, [])

  @spec show(String.t() | JS.t(), keyword() | String.t()) :: JS.t()
  def show(selector, opts) when is_binary(selector) and is_list(opts),
    do: show(%JS{}, selector, opts)

  def show(%JS{} = js, selector) when is_binary(selector), do: show(js, selector, [])

  @spec show(JS.t(), String.t(), keyword()) :: JS.t()
  def show(%JS{} = js, selector, opts) do
    JS.show(js,
      to: selector,
      display: Keyword.get(opts, :display, "block"),
      time: 200,
      transition:
        {"transition-all ease-out duration-200", "opacity-0 translate-y-2",
         "opacity-100 translate-y-0"}
    )
  end

  @doc "Fades an element out."
  @spec hide(JS.t(), String.t()) :: JS.t()
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition:
        {"transition-all ease-in duration-150", "opacity-100 translate-y-0",
         "opacity-0 translate-y-2"}
    )
  end
end

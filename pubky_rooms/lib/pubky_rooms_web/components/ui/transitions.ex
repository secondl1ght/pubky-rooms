defmodule PubkyRoomsWeb.UI.Transitions do
  @moduledoc """
  Shared `Phoenix.LiveView.JS` transitions used by the component library.
  """

  alias Phoenix.LiveView.JS

  @doc "Fades an element in (opacity + slight lift)."
  @spec show(JS.t(), String.t()) :: JS.t()
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
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

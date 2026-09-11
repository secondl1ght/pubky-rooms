defmodule PubkyRoomsWeb.UI.Layout do
  @moduledoc """
  Page-level layout primitives: the centered container and the
  sidebar / content / aside row used by Pubky App pages.
  """
  use Phoenix.Component

  @doc "The centered page container with the standard gutters."
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def container(assigns) do
    ~H"""
    <div class={["mx-auto w-full max-w-(--container-max-width) px-4 lg:px-6 xl:px-0", @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A page row: optional sticky left sidebar (visible from `lg`), flexible
  content, optional right aside (visible from `xl`).

      <.page>
        <:sidebar>…filters…</:sidebar>
        …content…
        <:aside>…who is here…</:aside>
      </.page>
  """
  attr :class, :any, default: nil
  attr :content_class, :any, default: nil
  slot :sidebar
  slot :aside
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <.container class={["pb-24 lg:pb-12", @class]}>
      <div class="flex gap-6">
        <aside
          :if={@sidebar != []}
          class="sticky top-(--header-offset-main) hidden w-(--filter-bar-width) shrink-0 flex-col gap-6 self-start lg:flex"
        >
          {render_slot(@sidebar)}
        </aside>
        <main class={["flex min-w-0 flex-1 flex-col gap-4", @content_class]}>
          {render_slot(@inner_block)}
        </main>
        <aside
          :if={@aside != []}
          class="sticky top-(--header-offset-main) hidden w-72 shrink-0 flex-col gap-6 self-start xl:flex"
        >
          {render_slot(@aside)}
        </aside>
      </div>
    </.container>
    """
  end

  @doc "A sidebar list item with an optional icon; the active item is white, the others grey."
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :icon, :string, default: nil
  attr :active, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def sidebar_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={[
        "flex cursor-pointer items-center gap-2 py-1 text-base font-medium transition-colors",
        (@active && "text-foreground") || "text-muted-foreground hover:text-foreground",
        @class
      ]}
      aria-current={@active && "page"}
      {@rest}
    >
      <span :if={@icon} class={[@icon, "size-5 shrink-0"]} aria-hidden="true" />
      <span class="truncate">{render_slot(@inner_block)}</span>
    </.link>
    """
  end
end

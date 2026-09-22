defmodule PubkyRoomsWeb.Layouts do
  @moduledoc """
  Layouts: the root HTML skeleton and the application shell (header,
  navigation, mobile tab bar, flash toasts).
  """
  use PubkyRoomsWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the application shell around page content.

      <Layouts.app flash={@flash} current_user={@current_user} active={:lobby}>
        …
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map,
    default: nil,
    doc: "the signed-in user (`%{pubky, name, avatar_url}`) or nil"

  attr :active, :atom,
    default: nil,
    doc: "the active navigation item: `:lobby`, `:new` or `:profile`"

  attr :back, :string, default: nil, doc: "an optional back link shown in the mobile header"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="sticky top-0 z-(--z-sticky-header) hidden w-full bg-linear-to-b from-background from-50% to-transparent lg:block lg:py-6">
      <nav class="mx-auto flex h-24 max-w-(--container-max-width) items-center justify-between gap-6 px-6 xl:px-0">
        <.logo navigate={~p"/"} />
        <div class="flex items-center gap-3">
          <.nav_button navigate={~p"/"} icon="lucide-house" label="Home" active={@active == :lobby} />
          <.nav_button
            navigate={~p"/rooms/new"}
            icon="lucide-plus"
            label="New room"
            active={@active == :new}
          />
          <.user_menu current_user={@current_user} active={@active == :profile} />
        </div>
      </nav>
    </header>

    <header class="sticky top-0 z-(--z-mobile-menu) w-full bg-linear-to-b from-background from-50% to-transparent lg:hidden">
      <div class="flex h-20 items-center justify-between px-4">
        <div class="flex size-12 items-center justify-start">
          <.link
            :if={@back}
            navigate={@back}
            class="flex size-12 items-center justify-center rounded-full text-secondary-foreground hover:bg-white/5"
            aria-label="Back"
          >
            <.icon name="lucide-arrow-left" class="size-6" />
          </.link>
        </div>
        <.logo navigate={~p"/"} />
        <div class="flex size-12 items-center justify-end">
          <.user_menu current_user={@current_user} active={@active == :profile} compact />
        </div>
      </div>
    </header>

    {render_slot(@inner_block)}

    <nav class="fixed bottom-0 z-40 w-full bg-linear-to-t from-background via-background/95 to-transparent px-3 pb-[max(1rem,env(safe-area-inset-bottom))] pt-4 lg:hidden">
      <div class="mx-auto flex max-w-[380px] items-center justify-around sm:max-w-[600px]">
        <.tab_item navigate={~p"/"} icon="lucide-house" label="Home" active={@active == :lobby} />
        <.tab_item
          navigate={~p"/rooms/new"}
          icon="lucide-plus"
          label="New room"
          active={@active == :new}
        />
        <.tab_item
          :if={@current_user}
          navigate={~p"/me"}
          icon="lucide-user-round"
          label="You"
          active={@active == :profile}
        />
        <.tab_item
          :if={!@current_user}
          navigate={~p"/login"}
          icon="lucide-log-in"
          label="Sign in"
          active={false}
        />
      </div>
    </nav>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_button(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-label={@label}
      aria-current={@active && "page"}
      data-tip={@label}
      class={[
        "tooltip flex size-12 items-center justify-center rounded-full border border-border shadow-xs backdrop-blur-md transition-all",
        "text-secondary-foreground hover:bg-accent",
        (@active && "bg-secondary") || "bg-white/5"
      ]}
    >
      <.icon name={@icon} class="size-6" />
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp tab_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-label={@label}
      aria-current={@active && "page"}
      class={[
        "flex size-12 items-center justify-center rounded-full p-3 transition-colors",
        "border border-border text-secondary-foreground backdrop-blur-sm",
        (@active && "bg-secondary") || "bg-white/5 hover:bg-white/10"
      ]}
    >
      <.icon name={@icon} class="size-6" />
    </.link>
    """
  end

  attr :current_user, :map, default: nil
  attr :active, :boolean, default: false
  attr :compact, :boolean, default: false

  defp user_menu(%{current_user: nil} = assigns) do
    ~H"""
    <.button :if={!@compact} navigate={~p"/login"}>
      <.icon name="lucide-key-round" class="size-4" /> Sign in
    </.button>
    <.link
      :if={@compact}
      navigate={~p"/login"}
      class="flex size-12 items-center justify-center rounded-full text-brand"
      aria-label="Sign in"
    >
      <.icon name="lucide-key-round" class="size-6" />
    </.link>
    """
  end

  defp user_menu(assigns) do
    ~H"""
    <.link
      navigate={~p"/me"}
      aria-label="Your profile"
      aria-current={@active && "page"}
      class={[
        "flex items-center justify-center rounded-full ring-2 ring-transparent",
        @active && "ring-brand"
      ]}
    >
      <.avatar
        src={@current_user.avatar_url}
        name={@current_user.name}
        pubky={@current_user.pubky}
        size="lg"
      />
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      aria-live="polite"
      class="pointer-events-none fixed bottom-24 right-4 z-60 flex flex-col items-end gap-2 lg:bottom-4"
    >
      <.flash kind={:success} flash={@flash} />
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="lucide-loader-circle" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="lucide-loader-circle" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end

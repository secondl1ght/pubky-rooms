defmodule PubkyRoomsWeb.Dev.StyleguideLive do
  @moduledoc """
  Development-only gallery of every `PubkyRoomsWeb.UI` component, used for
  visual QA against Pubky App. Mounted at `/dev/ui` when `dev_routes` is on.
  """
  use PubkyRoomsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    user = %{
      pubky: "ihaqcthsdbk751sxctk849bdr7yz7a934qen5gmpcbwcur49i97y",
      name: "Satoshi",
      avatar_url: nil
    }

    form = to_form(%{"name" => "", "topic" => "", "visibility" => "public"}, as: :room)

    {:ok,
     assign(socket, page_title: "Styleguide", current_user: user, form: form, signed_in: true)}
  end

  @impl true
  def handle_event("toggle-user", _params, socket) do
    {:noreply, update(socket, :signed_in, &(!&1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={(@signed_in && @current_user) || nil} active={:lobby}>
      <.page>
        <:sidebar>
          <div class="flex flex-col gap-1">
            <.section_title class="mb-2">Sections</.section_title>
            <.sidebar_item href="#type" icon="lucide-type">Typography</.sidebar_item>
            <.sidebar_item href="#buttons" icon="lucide-mouse-pointer-click" active>
              Buttons
            </.sidebar_item>
            <.sidebar_item href="#cards" icon="lucide-layout-panel-top">Cards</.sidebar_item>
            <.sidebar_item href="#tags" icon="lucide-tag">Tags</.sidebar_item>
            <.sidebar_item href="#forms" icon="lucide-text-cursor-input">Forms</.sidebar_item>
          </div>
          <.button variant="secondary" size="sm" phx-click="toggle-user">Toggle signed in</.button>
        </:sidebar>
        <.fab href="#forms" label="Open a room" />

        <section id="type" class="flex flex-col gap-3">
          <.typography size="2xl" tag="h1">
            Sign in to <span class="text-brand">Rooms.</span>
          </.typography>
          <.typography size="xl" tag="h2">Heading xl</.typography>
          <.typography size="lg" tag="h3">Heading lg</.typography>
          <.typography size="md">
            Body md — Rooms are live chats where every message is a file on your own homeserver.
          </.typography>
          <.typography size="sm" class="text-muted-foreground">Body sm, muted.</.typography>
          <.typography size="xs" class="text-muted-foreground">Caption xs.</.typography>
        </section>

        <section id="buttons" class="flex flex-col gap-4">
          <.section_title>Buttons</.section_title>
          <div class="flex flex-wrap items-center gap-3">
            <.button>Default</.button>
            <.button variant="brand">Brand</.button>
            <.button variant="secondary">Secondary</.button>
            <.button variant="ghost">Ghost</.button>
            <.button variant="outline">Outline</.button>
            <.button variant="destructive">Destructive</.button>
            <.button variant="destructive-soft">Destructive soft</.button>
            <.button variant="link">Link</.button>
            <.button variant="dark">Dark</.button>
            <.button variant="dark-outline">Dark outline</.button>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <.button size="sm"><.icon name="lucide-reply" class="size-4" /> Small</.button>
            <.button size="lg" variant="brand">Large CTA</.button>
            <.button size="icon" variant="secondary" aria-label="Settings"><.icon
              name="lucide-settings"
              class="size-4"
            /></.button>
            <.button size="icon-lg" variant="secondary" aria-label="Home"><.icon
              name="lucide-house"
              class="size-6"
            /></.button>
            <.button disabled>Disabled</.button>
            <.spinner />
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <.badge>12</.badge>
            <.badge variant="secondary">secondary</.badge>
            <.badge variant="brand">brand</.badge>
            <.badge variant="brand-soft"><.icon name="lucide-radio" class="size-3" /> live</.badge>
            <.badge variant="destructive">banned</.badge>
            <.badge variant="destructive-soft">
              <.icon name="lucide-door-closed" class="size-3" /> closed
            </.badge>
            <.badge variant="outline">outline</.badge>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <.avatar name="Satoshi" pubky="ihaqcth" size="xs" />
            <.avatar name="Satoshi" pubky="ihaqcth" size="sm" />
            <.avatar name="Hal" pubky="8um71" size="md" />
            <.avatar name="Ada" pubky="abc" />
            <.avatar name="Grace" pubky="def" size="lg" />
            <.avatar name="Linus" pubky="ghi" size="xl" />
            <.avatar name="Pubky" src={~p"/images/pubky-favicon.svg"} size="xl" />
            <.avatar src="/images/does-not-exist.png" name="Broken" pubky="zzz" size="lg" />
          </div>
        </section>

        <section id="cards" class="flex flex-col gap-4">
          <.section_title>Cards</.section_title>
          <div class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
            <.card>
              <.card_header>
                <.card_title>Bitcoin devs</.card_title>
                <.card_description>Protocol talk, PRs, and review requests.</.card_description>
              </.card_header>
              <.card_content class="flex flex-wrap gap-2">
                <.tag label="bitcoin" count={12} />
                <.tag label="dev" count={3} />
              </.card_content>
              <.card_footer class="justify-between text-sm text-muted-foreground">
                <span class="flex items-center gap-1.5"><.icon name="lucide-users" class="size-4" />
                42 members</span>
                <.button size="sm">Join</.button>
              </.card_footer>
            </.card>
            <.card variant="post">
              <div class="flex flex-col gap-4 p-6">
                <div class="flex items-center gap-3">
                  <.avatar name="Satoshi" pubky="ihaqcth" />
                  <div class="flex min-w-0 flex-col">
                    <span class="text-base font-bold leading-5">Satoshi</span>
                    <span class="text-xs text-muted-foreground">ihaqcth…i97y · 2 min ago</span>
                  </div>
                </div>
                <p class="text-base text-secondary-foreground">
                  Every message here is a file on my homeserver. This client only relays it.
                </p>
                <div class="flex items-center justify-end gap-2">
                  <.button variant="outline" size="sm"><.icon name="lucide-smile-plus" class="size-4" />
                  3</.button>
                  <.button variant="outline" size="sm"><.icon name="lucide-reply" class="size-4" /></.button>
                  <.button variant="outline" size="icon" aria-label="More"><.icon
                    name="lucide-ellipsis"
                    class="size-4"
                  /></.button>
                </div>
              </div>
            </.card>
          </div>
          <.empty_state icon="lucide-messages-square" title="No rooms yet">
            Create one and invite people with a link.
            <:actions>
              <.button variant="brand"><.icon name="lucide-plus" class="size-4" /> Create room</.button>
              <.button variant="secondary">Explore</.button>
            </:actions>
          </.empty_state>
          <div class="flex flex-col gap-2">
            <.skeleton class="h-4 w-1/3" />
            <.skeleton class="h-4 w-2/3" />
            <.skeleton class="h-24 w-full" />
          </div>
        </section>

        <section id="tags" class="flex flex-col gap-4">
          <.section_title>Tags</.section_title>
          <div class="flex flex-wrap gap-2">
            <.tag
              :for={
                l <-
                  ~w(bitcoin synonym bitkit pubky blocktank tether music art elixir phoenix rooms hello)
              }
              label={l}
              count={:erlang.phash2(l, 40)}
            />
            <.tag label="selected" selected />
          </div>
        </section>

        <section id="forms" class="flex flex-col gap-4">
          <.section_title>Forms &amp; dialog</.section_title>
          <.card>
            <.card_content>
              <.form for={@form} id="room-form" class="flex flex-col gap-4" phx-submit="noop">
                <.input
                  field={@form[:name]}
                  label="Room name"
                  placeholder="Bitcoin devs"
                  maxlength="64"
                />
                <.input
                  field={@form[:topic]}
                  type="textarea"
                  label="Topic"
                  placeholder="What is this room about?"
                  rows="2"
                  hint="Up to 280 characters."
                />
                <.input
                  field={@form[:visibility]}
                  type="select"
                  label="Visibility"
                  options={[Listed: "public", Unlisted: "unlisted"]}
                />
                <.input name="agree" value="true" type="checkbox" label="Publish tags for discovery" />
                <div class="rounded-md border border-dashed border-input p-6">
                  <.input
                    name="message"
                    value=""
                    type="textarea"
                    variant="inline"
                    placeholder="Say hello…"
                  />
                </div>
                <div class="flex justify-end gap-2">
                  <.button variant="ghost" phx-click={show_dialog("demo-dialog")}>Open dialog</.button>
                  <.button variant="brand" type="submit">Create room</.button>
                </div>
              </.form>
            </.card_content>
          </.card>
          <.dialog id="demo-dialog">
            <:title>New room</:title>
            <:description>Rooms live on your homeserver. Anyone with the link can read.</:description>
            <.input name="dialog-name" value="" label="Room name" placeholder="Bitcoin devs" />
            <:footer>
              <.button variant="ghost" phx-click={hide_dialog("demo-dialog")}>Cancel</.button>
              <.button variant="brand" phx-click={hide_dialog("demo-dialog")}>Create</.button>
            </:footer>
          </.dialog>
        </section>

        <:aside>
          <.card class="gap-4 py-5">
            <.card_header>
              <.section_title class="text-xl">Here now · 3</.section_title>
            </.card_header>
            <.card_content class="flex flex-col gap-3">
              <div
                :for={{n, p} <- [{"Satoshi", "ihaq"}, {"Hal", "8um7"}, {"Ada", "abc"}]}
                class="flex items-center gap-3"
              >
                <.avatar name={n} pubky={p} size="md" />
                <span class="text-sm font-semibold">{n}</span>
                <span class="ml-auto size-2 rounded-full bg-brand" />
              </div>
            </.card_content>
          </.card>
        </:aside>
      </.page>
    </Layouts.app>
    """
  end
end

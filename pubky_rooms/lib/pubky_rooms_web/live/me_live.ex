defmodule PubkyRoomsWeb.MeLive do
  @moduledoc "The signed-in user's page: identity, session, sign out."
  use PubkyRoomsWeb, :live_view

  alias PubkyRooms.Auth.GrantLogin

  on_mount {PubkyRoomsWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "You", capabilities: GrantLogin.capabilities())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active={:profile}>
      <.page content_class="mx-auto w-full max-w-2xl">
        <.card>
          <.card_content class="flex flex-col gap-6">
            <div class="flex items-center gap-4">
              <.avatar
                src={@current_user.avatar_url}
                name={@current_user.name}
                pubky={@current_user.pubky}
                size="xl"
              />
              <div class="flex min-w-0 flex-col gap-1">
                <.typography size="lg" tag="h1">{@current_user.name}</.typography>
                <p
                  class="truncate font-mono text-xs text-muted-foreground"
                  title={@current_user.pubky}
                >
                  {@current_user.pubky}
                </p>
              </div>
            </div>

            <dl class="grid grid-cols-1 gap-3 text-sm sm:grid-cols-[auto_1fr] sm:gap-x-6">
              <dt class="text-muted-foreground">Signed in with</dt>
              <dd class="flex items-center gap-2">
                <.icon name="lucide-key-round" class="size-4 text-brand" /> Pubky Ring
              </dd>
              <dt class="text-muted-foreground">Access granted</dt>
              <dd class="flex flex-wrap gap-1.5">
                <.badge :for={cap <- @capabilities} variant="secondary"><code>{cap}</code></.badge>
              </dd>
            </dl>

            <div class="flex flex-wrap gap-2">
              <.button variant="destructive-soft" href={~p"/logout"} method="delete">
                <.icon name="lucide-log-out" class="size-4" /> Sign out
              </.button>
            </div>
          </.card_content>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end

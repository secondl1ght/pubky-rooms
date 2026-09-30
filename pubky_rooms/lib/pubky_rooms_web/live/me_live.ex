defmodule PubkyRoomsWeb.MeLive do
  @moduledoc """
  The signed-in user's page: identity, display name, session, sign out.

  The display name comes from the user's Pubky App profile when they have
  one; otherwise they can set a Rooms nickname here, which is written to
  `/pub/pubky-rooms/profile.json` on their homeserver.
  """
  use PubkyRoomsWeb, :live_view

  alias PubkyRooms.Auth.GrantLogin
  alias PubkyRooms.Profiles.LocalProfile
  alias PubkyRooms.Rooms

  on_mount {PubkyRoomsWeb.UserAuth, :require_authenticated}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "You", capabilities: GrantLogin.capabilities(), saving: false)
     |> assign(nickname: nickname_form(socket.assigns.current_user))}
  end

  @impl true
  def handle_event("save_nickname", %{"nickname" => %{"name" => name}}, socket)
      when is_binary(name) do
    sid = socket.assigns.sid

    {:noreply,
     socket
     |> assign(saving: true, nickname: nickname_form(name))
     |> start_async(:save, fn -> Rooms.set_nickname(sid, name) end)}
  end

  def handle_event("clear_nickname", _params, socket) do
    sid = socket.assigns.sid

    {:noreply,
     socket |> assign(saving: true) |> start_async(:clear, fn -> Rooms.clear_nickname(sid) end)}
  end

  # Malformed payloads (a hand-crafted event) are ignored rather than crashing
  # the view, whose crash report would log its assigns.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:save, {:ok, :ok}, socket) do
    {:noreply,
     socket |> assign(saving: false) |> put_flash(:success, "Nickname saved to your homeserver.")}
  end

  def handle_async(:save, {:ok, {:error, reason}}, socket) when is_binary(reason) do
    {:noreply,
     assign(socket,
       saving: false,
       nickname: nickname_form(socket.assigns.nickname.params["name"], reason)
     )}
  end

  def handle_async(:clear, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(saving: false, nickname: nickname_form(""))
     |> put_flash(:info, "Nickname removed.")}
  end

  def handle_async(_name, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(saving: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  def handle_async(_name, {:exit, reason}, socket) do
    {:noreply, socket |> assign(saving: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp nickname_form(%{source: :local, name: name}), do: nickname_form(name)
  defp nickname_form(%{source: _}), do: nickname_form("")

  defp nickname_form(name, error \\ nil) when is_binary(name) do
    errors = if error, do: [name: {error, []}], else: []
    to_form(%{"name" => name}, as: :nickname, errors: errors)
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
                <div class="flex min-w-0 items-center gap-1">
                  <p
                    class="truncate font-mono text-xs text-muted-foreground"
                    title={@current_user.pubky}
                  >
                    {@current_user.pubky}
                  </p>
                  <.button
                    variant="ghost"
                    size="icon-sm"
                    id="copy-pubky"
                    phx-hook="Clipboard"
                    data-copy={@current_user.pubky}
                    aria-label="Copy your public key"
                    data-tip="Copy key"
                    class="tooltip shrink-0 text-muted-foreground hover:text-foreground"
                  >
                    <.icon name="lucide-copy" class="size-3.5" />
                  </.button>
                </div>
                <p class="text-xs text-muted-foreground">
                  <%= case @current_user.source do %>
                    <% :pubky_app -> %>
                      Name and picture from your Pubky App profile
                    <% :local -> %>
                      Rooms nickname (no Pubky App profile found)
                    <% _ -> %>
                      No profile found yet — shown as your shortened key
                  <% end %>
                </p>
              </div>
            </div>

            <.form
              :if={@current_user.source != :pubky_app}
              for={@nickname}
              id="nickname-form"
              phx-submit="save_nickname"
              class="flex flex-col gap-3 rounded-md border border-input/60 p-4"
            >
              <.input
                field={@nickname[:name]}
                label="Display name in Rooms"
                hint={"Up to #{LocalProfile.name_max()} characters. A Pubky App profile name takes precedence."}
                placeholder="How should people see you?"
                maxlength={LocalProfile.name_max()}
                autocomplete="nickname"
              />
              <div class="flex flex-wrap gap-2">
                <.button variant="brand" type="submit" disabled={@saving} class="w-full sm:w-auto">
                  <.spinner :if={@saving} class="size-4" />
                  <.icon :if={!@saving} name="lucide-save" class="size-4" /> Save name
                </.button>
                <.button
                  :if={@current_user.source == :local}
                  variant="ghost"
                  type="button"
                  phx-click="clear_nickname"
                  disabled={@saving}
                  class="w-full sm:w-auto"
                >
                  Remove
                </.button>
              </div>
            </.form>

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

            <div class="flex flex-wrap justify-end gap-2">
              <.button variant="secondary" href={~p"/logout"} method="delete" class="w-full sm:w-auto">
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

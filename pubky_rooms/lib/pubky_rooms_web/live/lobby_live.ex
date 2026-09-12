defmodule PubkyRoomsWeb.LobbyLive do
  @moduledoc """
  The lobby: the rooms you created and joined, and the "new room" dialog.

  Room lists come from `PubkyRooms.Rooms.Directory` and refresh live from
  its broadcasts. Creating a room writes two files to the creator's homeserver
  and then navigates into the room.
  """
  use PubkyRoomsWeb, :live_view

  alias PubkyRooms.{Profiles, Rooms}
  alias PubkyRooms.Rooms.{Directory, Room}
  alias PubkyRoomsWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Directory.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Rooms", form: new_form(), creating: false)
     |> load_rooms()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new, current_user: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Sign in to create a room.")
     |> redirect(to: ~p"/login?return_to=/rooms/new")}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", %{"room" => params}, socket) do
    {:noreply, assign(socket, form: form_for(params))}
  end

  def handle_event(
        "create",
        %{"room" => params},
        %{assigns: %{current_user: %{pubky: pubky}, sid: sid}} = socket
      ) do
    case Room.validate(params) do
      {:ok, _fields} ->
        {:noreply,
         socket
         |> assign(creating: true, form: form_for(params))
         |> start_async(:create, fn -> Rooms.create_room(sid, pubky, params) end)}

      {:error, errors} ->
        {:noreply, assign(socket, form: form_for(params, errors))}
    end
  end

  def handle_event("create", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/login?return_to=/rooms/new")}
  end

  @impl true
  def handle_async(:create, {:ok, {:ok, %Room{} = room}}, socket) do
    {:noreply,
     socket
     |> assign(creating: false)
     |> put_flash(:success, "Room created on your homeserver.")
     |> push_navigate(to: ~p"/r/#{room.creator}/#{room.id}")}
  end

  def handle_async(:create, {:ok, {:error, errors}}, socket) when is_list(errors) do
    {:noreply,
     assign(socket, creating: false, form: form_for(socket.assigns.form.params, errors))}
  end

  def handle_async(:create, {:ok, {:error, :unauthorized}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, Rooms.explain(:unauthorized))
     |> redirect(to: ~p"/logout")}
  end

  def handle_async(:create, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(creating: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  def handle_async(:create, {:exit, reason}, socket) do
    {:noreply, socket |> assign(creating: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  @impl true
  def handle_info({:directory, _event}, socket), do: {:noreply, load_rooms(socket)}

  def handle_info({:profile_updated, z32, profile}, socket) do
    if Map.has_key?(socket.assigns.profiles, z32),
      do: {:noreply, assign(socket, profiles: Map.put(socket.assigns.profiles, z32, profile))},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_rooms(%{assigns: %{current_user: nil}} = socket),
    do: assign(socket, created: [], joined: [], profiles: %{})

  defp load_rooms(%{assigns: %{current_user: %{pubky: pubky}}} = socket) do
    %{created: created, joined: joined} = Directory.rooms_of(pubky)
    creators = Enum.map(created ++ joined, & &1.creator)
    profiles = Map.new(creators, &{&1, Profiles.get(&1)})
    assign(socket, created: created, joined: joined, profiles: profiles)
  end

  defp new_form, do: form_for(%{"name" => "", "topic" => "", "visibility" => "public"})
  defp form_for(params, errors \\ []), do: to_form(params, as: :room, errors: errors)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      active={if(@live_action == :new, do: :new, else: :lobby)}
    >
      <.page>
        <:sidebar>
          <div class="flex flex-col gap-1">
            <.section_title class="mb-2">Rooms</.section_title>
            <.sidebar_item navigate={~p"/"} icon="lucide-house" active={@live_action == :index}>
              Your rooms
            </.sidebar_item>
            <.sidebar_item patch={~p"/rooms/new"} icon="lucide-plus" active={@live_action == :new}>
              New room
            </.sidebar_item>
          </div>
          <div class="flex flex-col gap-1">
            <.section_title class="mb-2">About</.section_title>
            <p class="text-sm text-muted-foreground">
              Every message is a file on its author's homeserver. This server only relays and never stores your chats.
            </p>
          </div>
        </:sidebar>

        <%= if @current_user do %>
          <section :if={@created != []} class="flex flex-col gap-3">
            <.section_title>Your rooms</.section_title>
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
              <.room_card :for={room <- @created} room={room} creator={@profiles[room.creator]} />
            </div>
          </section>
          <section :if={@joined != []} class="flex flex-col gap-3">
            <.section_title>Joined</.section_title>
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
              <.room_card :for={room <- @joined} room={room} creator={@profiles[room.creator]} />
            </div>
          </section>
          <.empty_state
            :if={@created == [] and @joined == []}
            icon="lucide-messages-square"
            title="No rooms yet"
          >
            Create a room and share its link. Rooms live on your homeserver, so they are yours to keep.
            <:actions>
              <.button variant="brand" patch={~p"/rooms/new"}>
                <.icon name="lucide-plus" class="size-4" /> Create a room
              </.button>
            </:actions>
          </.empty_state>
        <% else %>
          <div class="flex flex-col gap-6 py-6 lg:py-16">
            <.typography size="2xl" tag="h1" class="max-w-2xl">
              Live rooms.<br />Your <span class="text-brand">homeserver.</span>
            </.typography>
            <.typography size="md" class="max-w-xl text-muted-foreground">
              Pubky Rooms are chat rooms where every message is a file on its author's own homeserver.
              Sign in with Pubky Ring, create a room, and share the link. Nothing here is locked in.
            </.typography>
            <div class="flex flex-wrap gap-3">
              <.button variant="brand" size="lg" navigate={~p"/login"}>
                <.icon name="lucide-key-round" class="size-4" /> Sign in with Pubky Ring
              </.button>
            </div>
          </div>
        <% end %>

        <:aside>
          <.card class="gap-4 py-5">
            <.card_header>
              <.section_title class="text-xl">How it works</.section_title>
            </.card_header>
            <.card_content class="flex flex-col gap-3 text-sm text-secondary-foreground">
              <p class="flex gap-2">
                <.icon name="lucide-file-json" class="mt-0.5 size-4 shrink-0 text-brand" />
                Messages are JSON files under <code class="text-xs">/pub/pubky-rooms/</code>
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-radio" class="mt-0.5 size-4 shrink-0 text-brand" />
                Homeserver event streams deliver them live
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-circle-check" class="mt-0.5 size-4 shrink-0 text-brand" />
                A check mark means your homeserver stored it
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-globe" class="mt-0.5 size-4 shrink-0 text-brand" />
                All rooms are public, like posts on Pubky App
              </p>
            </.card_content>
          </.card>
        </:aside>
      </.page>

      <.fab :if={@current_user} patch={~p"/rooms/new"} label="New room" />

      <.dialog :if={@live_action == :new} id="new-room" show on_cancel={JS.patch(~p"/")}>
        <:title>New room</:title>
        <:description>
          The room definition is written to your homeserver; you can rename or close it later.
          All rooms are public: anyone with the link can read them. "Unlisted" only keeps a room out of discovery.
        </:description>
        <.form
          for={@form}
          id="new-room-form"
          phx-change="validate"
          phx-submit="create"
          class="flex flex-col gap-4"
        >
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="Bitcoin devs"
            maxlength={Room.name_max()}
            autofocus
          />
          <.input
            field={@form[:topic]}
            type="textarea"
            label="Topic"
            placeholder="What is this room about? (optional)"
            rows="2"
            maxlength={Room.topic_max()}
          />
          <.input
            field={@form[:visibility]}
            type="select"
            label="Visibility"
            options={[
              {"Public — listed for discovery", "public"},
              {"Unlisted — not listed, still readable by anyone with the link", "unlisted"}
            ]}
          />
        </.form>
        <:footer>
          <.button variant="ghost" phx-click={JS.patch(~p"/")}>Cancel</.button>
          <.button variant="brand" type="submit" form="new-room-form" disabled={@creating}>
            <.spinner :if={@creating} class="size-4" />
            <.icon :if={!@creating} name="lucide-plus" class="size-4" /> Create room
          </.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  attr :room, Room, required: true
  attr :creator, :map, required: true, doc: "the creator's profile"

  defp room_card(assigns) do
    ref = Room.ref(assigns.room)

    assigns =
      assign(assigns,
        member_count: Directory.member_count(ref),
        activity: Directory.last_activity(ref)
      )

    ~H"""
    <.link navigate={~p"/r/#{@room.creator}/#{@room.id}"} class="group block">
      <.card class="h-full gap-4 py-5 transition-colors group-hover:bg-accent/40">
        <.card_header class="gap-2">
          <div class="flex items-start justify-between gap-3">
            <.card_title class="truncate">{@room.name}</.card_title>
            <.badge :if={@room.visibility == "unlisted"} variant="outline">
              <.icon name="lucide-link" class="size-3" /> unlisted
            </.badge>
          </div>
          <.card_description :if={@room.topic} class="line-clamp-2">{@room.topic}</.card_description>
        </.card_header>
        <.card_footer class="justify-between gap-3 text-xs text-muted-foreground">
          <span class="flex min-w-0 items-center gap-2">
            <.avatar name={@creator.name} pubky={@creator.pubky} size="xs" />
            <span class="truncate">{@creator.name}</span>
          </span>
          <span class="flex shrink-0 items-center gap-3">
            <span class="flex items-center gap-1"><.icon name="lucide-users" class="size-3.5" /> {@member_count}</span>
            <span :if={@activity}>{Format.relative(@activity)}</span>
          </span>
        </.card_footer>
      </.card>
    </.link>
    """
  end
end

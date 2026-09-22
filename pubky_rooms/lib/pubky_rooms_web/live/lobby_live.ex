defmodule PubkyRoomsWeb.LobbyLive do
  @moduledoc """
  The lobby: the rooms you created and joined, the public rooms this node
  knows about, and the "new room" dialog.

  Room lists come from `PubkyRooms.Rooms.Directory` and refresh live from
  its broadcasts (debounced: every new message anywhere bumps a room's
  activity). Creating a room writes two files to the creator's homeserver and
  then navigates into the room.
  """
  use PubkyRoomsWeb, :live_view

  alias PubkyRooms.{Profiles, Rooms}
  alias PubkyRooms.Rooms.{Directory, Room}
  alias PubkyRooms.Tags.Tag
  alias PubkyRoomsWeb.{Format, Presence}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Directory.subscribe()
      Presence.subscribe(Presence.lobby_topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Lobby",
       form: new_form(),
       creating: false,
       stats_topics: MapSet.new(),
       reload_timer: nil,
       tag_filter: nil
     )
     |> load_rooms()
     |> load_presence()}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :new, current_user: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Sign in to open a room.")
     |> redirect(to: ~p"/login?return_to=/rooms/new")}
  end

  def handle_params(params, _uri, socket) do
    filter =
      case Tag.normalize(params["tag"]) do
        {:ok, label} -> label
        {:error, _} -> nil
      end

    if filter == socket.assigns.tag_filter,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(tag_filter: filter) |> load_rooms() |> load_presence()}
  end

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
     |> put_flash(:success, "Room opened. It lives on your homeserver.")
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
  def handle_info({:directory, _event}, %{assigns: %{reload_timer: nil}} = socket),
    do: {:noreply, assign(socket, reload_timer: Process.send_after(self(), :reload_rooms, 500))}

  def handle_info({:directory, _event}, socket), do: {:noreply, socket}

  def handle_info(:reload_rooms, socket),
    do: {:noreply, socket |> assign(reload_timer: nil) |> load_rooms() |> load_presence()}

  def handle_info({:presence, _event}, socket), do: {:noreply, load_presence(socket)}

  def handle_info({:room_stats, ref, %{viewers: viewers}}, socket) do
    {:noreply, assign(socket, room_viewers: Map.put(socket.assigns.room_viewers, ref, viewers))}
  end

  def handle_info({:profile_updated, z32, profile}, socket) do
    if Map.has_key?(socket.assigns.profiles, z32),
      do: {:noreply, assign(socket, profiles: Map.put(socket.assigns.profiles, z32, profile))},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_rooms(socket) do
    %{created: created, joined: joined, closed: closed} =
      case socket.assigns.current_user do
        nil -> %{created: [], joined: [], closed: []}
        %{pubky: pubky} -> Directory.rooms_of(pubky)
      end

    mine = MapSet.new(created ++ joined, &Room.ref/1)

    # without a filter, own rooms are listed above and not repeated; with a tag
    # filter the list answers "which rooms are tagged X", own ones included
    public =
      case socket.assigns.tag_filter do
        nil ->
          Enum.reject(Directory.public_rooms(), &MapSet.member?(mine, Room.ref(&1)))

        label ->
          tagged = MapSet.new(Directory.rooms_tagged(label))
          Enum.filter(Directory.public_rooms(), &MapSet.member?(tagged, Room.ref(&1)))
      end

    all = created ++ joined ++ public ++ closed
    profiles = Map.new(all, &{&1.creator, Profiles.get(&1.creator)})

    socket
    |> assign(
      created: created,
      joined: joined,
      public: public,
      closed: closed,
      profiles: profiles,
      popular_tags: Directory.popular_tags(),
      room_tags: Map.new(all, &{Room.ref(&1), Directory.tags_of(Room.ref(&1))})
    )
    |> load_viewers()
  end

  defp listed_refs(socket) do
    %{created: created, joined: joined, public: public, closed: closed} = socket.assigns
    Enum.map(created ++ joined ++ public ++ closed, &Room.ref/1)
  end

  # Viewer totals (signed in or not) per listed room, kept live through each
  # room's low-volume stats topic and its presence topic; subscriptions follow
  # the listed set.
  defp load_viewers(socket) do
    refs = listed_refs(socket)

    wanted =
      MapSet.new(
        Enum.map(refs, &Rooms.stats_topic/1) ++
          Enum.map(refs, &("proxy:" <> Presence.room_topic(&1)))
      )

    current = socket.assigns.stats_topics

    if connected?(socket) do
      for t <- MapSet.difference(wanted, current),
          do: Phoenix.PubSub.subscribe(PubkyRooms.PubSub, t)

      for t <- MapSet.difference(current, wanted),
          do: Phoenix.PubSub.unsubscribe(PubkyRooms.PubSub, t)
    end

    assign(socket,
      stats_topics: wanted,
      room_viewers: Map.new(refs, &{&1, Rooms.viewer_count(&1)})
    )
  end

  # App-wide online count and per-room online counts (signed-in users only).
  defp load_presence(socket) do
    assign(socket,
      online_count: Presence.online_count(Presence.lobby_topic()),
      room_online: socket |> listed_refs() |> Map.new(&{&1, Rooms.online_stats(&1)})
    )
  end

  defp new_form,
    do: form_for(%{"name" => "", "topic" => "", "visibility" => "public", "tags" => ""})

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
            <.sidebar_item navigate={~p"/"} icon="lucide-door-open" active={@live_action == :index}>
              Lobby
            </.sidebar_item>
            <.sidebar_item patch={~p"/rooms/new"} icon="lucide-plus" active={@live_action == :new}>
              Open a room
            </.sidebar_item>
            <.sidebar_item href="#directory" icon="lucide-signpost">
              Directory
            </.sidebar_item>
          </div>
          <div :if={@popular_tags != []} class="flex flex-col gap-2" id="popular-tags">
            <.section_title class="mb-1">Tags</.section_title>
            <div class="flex flex-wrap gap-1.5">
              <.tag
                :for={{label, _rooms} <- @popular_tags}
                label={label}
                size="sm"
                selected={@tag_filter == label}
                phx-click={JS.patch(if(@tag_filter == label, do: ~p"/", else: ~p"/?tag=#{label}"))}
              />
            </div>
          </div>
          <p class="flex items-center gap-2.5 text-sm text-secondary-foreground" id="lobby-online">
            <.live_dot />
            {@online_count} {if @online_count == 1, do: "person", else: "people"} online
          </p>
        </:sidebar>

        <%= if @current_user do %>
          <section :if={@created != []} class="flex flex-col gap-3">
            <.section_title>Your rooms</.section_title>
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
              <.room_card
                :for={room <- @created}
                room={room}
                creator={@profiles[room.creator]}
                online={@room_online[Room.ref(room)]}
                viewers={@room_viewers[Room.ref(room)] || 0}
                tags={@room_tags[Room.ref(room)] || []}
              />
            </div>
          </section>
          <section :if={@joined != []} class="flex flex-col gap-3">
            <.section_title>Joined</.section_title>
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
              <.room_card
                :for={room <- @joined}
                room={room}
                creator={@profiles[room.creator]}
                online={@room_online[Room.ref(room)]}
                viewers={@room_viewers[Room.ref(room)] || 0}
                tags={@room_tags[Room.ref(room)] || []}
              />
            </div>
          </section>
          <details :if={@closed != []} id="closed-rooms" class="group flex flex-col gap-3">
            <summary class="flex cursor-pointer list-none items-center gap-2 text-muted-foreground marker:content-none">
              <.icon
                name="lucide-chevron-right"
                class="size-4 transition-transform group-open:rotate-90"
              />
              <.section_title class="text-muted-foreground">Closed</.section_title>
              <.badge variant="outline">{length(@closed)}</.badge>
              <span class="text-xs">read-only archives of rooms you were in</span>
            </summary>
            <div class="grid grid-cols-1 gap-3 pt-3 md:grid-cols-2 lg:gap-6">
              <.room_card
                :for={room <- @closed}
                room={room}
                creator={@profiles[room.creator]}
                online={@room_online[Room.ref(room)]}
                viewers={@room_viewers[Room.ref(room)] || 0}
                tags={@room_tags[Room.ref(room)] || []}
              />
            </div>
          </details>
          <.empty_state
            :if={@created == [] and @joined == [] and @closed == []}
            icon="lucide-messages-square"
            title="No rooms yet"
          >
            Open a room and share its link. It is written to your homeserver, so it is yours to keep.
            <:actions>
              <.button variant="brand" patch={~p"/rooms/new"}>
                <.icon name="lucide-plus" class="size-4" /> Open a room
              </.button>
            </:actions>
          </.empty_state>
        <% else %>
          <div class="flex flex-col gap-6 py-6 lg:py-10">
            <.typography size="2xl" tag="h1" class="max-w-2xl">
              Live rooms.<br />Your <span class="text-brand">homeserver.</span>
            </.typography>
            <.typography size="md" class="max-w-xl text-muted-foreground">
              Group chat where every message is yours to keep. Sign in with Pubky Ring, open a room,
              share the link. Nothing here is locked in.
            </.typography>
            <div class="flex flex-wrap gap-3">
              <.button variant="brand" size="lg" navigate={~p"/login"} class="w-full sm:w-auto">
                <.icon name="lucide-key-round" class="size-4" /> Sign in with Pubky Ring
              </.button>
            </div>
          </div>
        <% end %>

        <section id="directory" class="flex flex-col gap-3">
          <div class="flex flex-wrap items-baseline justify-between gap-3">
            <.section_title>
              Directory<span :if={@tag_filter} class="text-muted-foreground"> · {@tag_filter}</span>
            </.section_title>
            <span :if={!@tag_filter} class="text-xs text-muted-foreground">Most recent activity first</span>
            <.link
              :if={@tag_filter}
              patch={~p"/"}
              class="text-xs text-muted-foreground hover:text-foreground"
            >
              Clear filter
            </.link>
          </div>
          <div :if={@public != []} class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
            <.room_card
              :for={room <- @public}
              room={room}
              creator={@profiles[room.creator]}
              online={@room_online[Room.ref(room)]}
              viewers={@room_viewers[Room.ref(room)] || 0}
              tags={@room_tags[Room.ref(room)] || []}
            />
          </div>
          <p :if={@public == [] and @tag_filter} class="text-sm text-muted-foreground">
            No public room is tagged "{@tag_filter}" yet.
          </p>
          <p :if={@public == [] and !@tag_filter} class="text-sm text-muted-foreground">
            No rooms yet. Open the first one.
          </p>
        </section>

        <:aside>
          <.card class="gap-4 py-5">
            <.card_header>
              <.section_title class="text-xl">How it works</.section_title>
            </.card_header>
            <.card_content class="flex flex-col gap-3 text-sm text-muted-foreground">
              <p class="flex gap-2">
                <.icon name="lucide-file-text" class="mt-0.5 size-4 shrink-0 text-brand" />
                <span>Every message is a file on its author's homeserver</span>
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-radio" class="mt-0.5 size-4 shrink-0 text-brand" />
                <span>Homeserver event streams deliver them live</span>
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-circle-check" class="mt-0.5 size-4 shrink-0 text-brand" />
                <span>A check mark means your homeserver stored it</span>
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-lock-open" class="mt-0.5 size-4 shrink-0 text-brand" />
                <span>
                  Nothing is locked in: your rooms live on your homeserver and work in any other Pubky client
                </span>
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-tag" class="mt-0.5 size-4 shrink-0 text-brand" />
                <span>Tag a room to help people find it, here and in Pubky App</span>
              </p>
              <p class="flex gap-2">
                <.icon name="lucide-globe" class="mt-0.5 size-4 shrink-0 text-brand" />
                <span>
                  All rooms are public for now, like posts on Pubky App. Private rooms come with private homeserver storage.
                </span>
              </p>
            </.card_content>
          </.card>
        </:aside>
      </.page>

      <.fab :if={@current_user} patch={~p"/rooms/new"} label="Open a room" />

      <.dialog :if={@live_action == :new} id="new-room" show on_cancel={JS.patch(~p"/")}>
        <:title>Open a room</:title>
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
          <.input
            :if={@form[:visibility].value != "unlisted"}
            field={@form[:tags]}
            label="Tags"
            placeholder="bitcoin, nostr, dev"
            hint={"Up to #{Tag.max_custom_labels()} labels for discovery, written as universal tags on your homeserver (every public room is also tagged “room”)."}
            autocomplete="off"
          />
        </.form>
        <:footer>
          <.button variant="ghost" phx-click={JS.patch(~p"/")}>Cancel</.button>
          <.button variant="brand" type="submit" form="new-room-form" disabled={@creating}>
            <.spinner :if={@creating} class="size-4" />
            <.icon :if={!@creating} name="lucide-plus" class="size-4" /> Open room
          </.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  attr :room, Room, required: true
  attr :creator, :map, required: true, doc: "the creator's profile"
  attr :online, :map, default: nil, doc: "signed-in presence: `%{users, tabs}`"
  attr :viewers, :integer, default: 0, doc: "everyone with the room open, signed in or not"
  attr :tags, :list, default: [], doc: "`Directory.tags_of/1` result; the top three are shown"

  defp room_card(assigns) do
    ref = Room.ref(assigns.room)
    %{users: users, tabs: tabs} = assigns.online || %{users: 0, tabs: 0}

    assigns =
      assign(assigns,
        member_count: Directory.member_count(ref),
        activity: Directory.last_activity(ref),
        online: users,
        anonymous: max(assigns.viewers - tabs, 0)
      )

    ~H"""
    <.link navigate={~p"/r/#{@room.creator}/#{@room.id}"} class="group block">
      <.card class="h-full gap-4 py-5 transition-colors group-hover:bg-accent/40">
        <.card_header class="gap-2">
          <div class="flex items-start justify-between gap-3">
            <.card_title class="truncate">{@room.name}</.card_title>
            <.badge :if={Room.closed?(@room)} variant="destructive-soft">
              <.icon name="lucide-door-closed" class="size-3" /> closed
            </.badge>
            <.badge :if={@room.visibility == "unlisted" and not Room.closed?(@room)} variant="outline">
              <.icon name="lucide-link" class="size-3" /> unlisted
            </.badge>
          </div>
          <.card_description :if={@room.topic} class="line-clamp-2">{@room.topic}</.card_description>
          <div :if={@tags != []} class="flex flex-wrap gap-1.5 pt-1">
            <.tag :for={t <- Enum.take(@tags, 3)} label={t.label} count={t.count} size="sm" static />
          </div>
        </.card_header>
        <.card_footer class="justify-between gap-3 text-xs text-muted-foreground">
          <span class="flex min-w-0 items-center gap-2">
            <.avatar src={@creator.avatar_url} name={@creator.name} pubky={@creator.pubky} size="xs" />
            <span class="truncate">{@creator.name}</span>
          </span>
          <span class="flex shrink-0 items-center gap-3">
            <span
              :if={@online > 0}
              class="flex items-center gap-1 text-secondary-foreground"
              title="Signed-in people in the room"
            >
              <.live_dot /> {@online}
            </span>
            <span :if={@anonymous > 0} class="flex items-center gap-1" title="Anonymous viewers">
              <.icon name="lucide-eye" class="size-3.5" /> {@anonymous}
            </span>
            <span class="flex items-center gap-1"><.icon name="lucide-users" class="size-3.5" /> {@member_count}</span>
            <span :if={@activity}>{Format.relative(@activity)}</span>
          </span>
        </.card_footer>
      </.card>
    </.link>
    """
  end
end

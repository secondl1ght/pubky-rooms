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
       tag_labels: [],
       tag_suggestions: [],
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
    # A fresh dialog every time it opens.
    socket =
      if socket.assigns.live_action == :new,
        do: assign(socket, form: new_form(), tag_labels: [], tag_suggestions: []),
        else: socket

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
  # Unlisted rooms are never tagged, so switching to Unlisted drops the chips
  # instead of carrying them invisibly until the room is opened.
  def handle_event("validate", %{"room" => params}, socket) do
    socket = assign(socket, form: form_for(params))

    if params["visibility"] == "unlisted",
      do: {:noreply, assign(socket, tag_labels: [], tag_suggestions: [])},
      else: {:noreply, socket}
  end

  # The tag input (UI.TagInput): chips live here, the hook only drives the field.
  def handle_event("add_tag", %{"label" => label}, %{assigns: %{tag_labels: labels}} = socket) do
    socket = assign(socket, tag_suggestions: [])

    with {:ok, normalized} <- Tag.normalize(label),
         false <- normalized in labels or normalized == Tag.auto_label(),
         true <- length(labels) < Tag.max_custom_labels() do
      {:noreply, assign(socket, tag_labels: labels ++ [normalized])}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("remove_tag", %{"label" => label}, %{assigns: %{tag_labels: labels}} = socket) do
    {:noreply, assign(socket, tag_labels: List.delete(labels, label))}
  end

  def handle_event("tag_query", %{"q" => q}, %{assigns: %{tag_labels: labels}} = socket)
      when is_binary(q) do
    known = socket.assigns.popular_tags |> Enum.map(fn {label, _rooms} -> label end)
    {:noreply, assign(socket, tag_suggestions: Tag.suggest(known, q, labels))}
  end

  def handle_event(
        "create",
        %{"room" => params},
        %{assigns: %{current_user: %{pubky: pubky}, sid: sid}} = socket
      ) do
    params = Map.put(params, "tags", Enum.join(socket.assigns.tag_labels, " "))

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

  # Malformed payloads (a hand-crafted event) are ignored rather than crashing
  # the view, whose crash report would log its assigns.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:create, {:ok, {:ok, %Room{} = room}}, socket) do
    {:noreply,
     socket
     |> assign(creating: false)
     |> put_flash(:success, "Room opened. Copy the link to invite people.")
     |> push_navigate(to: ~p"/r/#{room.creator}/#{room.id}")}
  end

  def handle_async(:create, {:ok, {:error, errors}}, socket) when is_list(errors) do
    {:noreply,
     assign(socket, creating: false, form: form_for(socket.assigns.form.params, errors))}
  end

  # The grant is gone: the next full request notices and drops the cookie
  # (see `PubkyRoomsWeb.UserAuth`), so the sign-in page is the right place.
  def handle_async(:create, {:ok, {:error, :unauthorized}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, Rooms.explain(:unauthorized))
     |> redirect(to: ~p"/login")}
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
    # filter the page is only the answer to "which rooms are tagged X" (own
    # ones included, the own-room sections are hidden meanwhile)
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
      # the automatic label is on every listed room: it says nothing here
      popular_tags:
        Enum.reject(Directory.popular_tags(), fn {label, _} -> label == Tag.auto_label() end),
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
          <p class="flex items-center gap-2.5 text-sm text-secondary-foreground" id="lobby-online">
            <.live_dot active={@online_count > 0} />
            {@online_count} {if @online_count == 1, do: "person", else: "people"} online
          </p>
          <div :if={@popular_tags != []} class="flex flex-col gap-2" id="popular-tags">
            <.section_title class="mb-1">Tags</.section_title>
            <.tag_chips tags={@popular_tags} filter={@tag_filter} class="flex-wrap" />
          </div>
        </:sidebar>

        <%= if @current_user do %>
          <section :if={@created != [] and is_nil(@tag_filter)} class="flex flex-col gap-3">
            <.section_title>Your rooms</.section_title>
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
              <.room_card
                :for={room <- @created}
                room={room}
                creator={@profiles[room.creator]}
                online={@room_online[Room.ref(room)]}
                viewers={@room_viewers[Room.ref(room)] || 0}
                tags={@room_tags[Room.ref(room)] || []}
                filter={@tag_filter}
              />
            </div>
          </section>
          <section :if={@joined != [] and is_nil(@tag_filter)} class="flex flex-col gap-3">
            <.section_title>Joined</.section_title>
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2 lg:gap-6">
              <.room_card
                :for={room <- @joined}
                room={room}
                creator={@profiles[room.creator]}
                online={@room_online[Room.ref(room)]}
                viewers={@room_viewers[Room.ref(room)] || 0}
                tags={@room_tags[Room.ref(room)] || []}
                filter={@tag_filter}
              />
            </div>
          </section>
          <details
            :if={@closed != [] and is_nil(@tag_filter)}
            id="closed-rooms"
            class="group flex flex-col gap-3"
          >
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
                filter={@tag_filter}
              />
            </div>
          </details>
          <.empty_state
            :if={@created == [] and @joined == [] and @closed == [] and is_nil(@tag_filter)}
            icon="lucide-messages-square"
            title="No rooms yet"
          >
            Open a room and it appears in the directory for everyone. Tag it so people find it here and in Pubky App, or share the link directly.
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
          <p class="flex items-center gap-2.5 text-sm text-secondary-foreground lg:hidden">
            <.live_dot active={@online_count > 0} />
            {@online_count} {if @online_count == 1, do: "person", else: "people"} online
          </p>
          <div :if={@popular_tags != []} class="flex flex-col gap-2 lg:hidden">
            <.section_title>Tags</.section_title>
            <.tag_chips
              tags={@popular_tags}
              filter={@tag_filter}
              class="-mx-4 overflow-x-auto px-4 pb-1"
            />
          </div>
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
              filter={@tag_filter}
            />
          </div>
          <.empty_state
            :if={@public == [] and @tag_filter}
            icon="lucide-tag"
            title={"Nothing tagged #{@tag_filter}"}
          >
            No room carries this tag yet.
          </.empty_state>
          <.empty_state
            :if={@public == [] and !@tag_filter and @created ++ @joined == []}
            icon="lucide-signpost"
            title="No rooms yet"
          >
            Open the first one.
          </.empty_state>
          <.empty_state
            :if={@public == [] and !@tag_filter and @created ++ @joined != []}
            icon="lucide-signpost"
            title="Nothing else listed"
          >
            You're already in every listed room. Share a link to bring more people in.
          </.empty_state>
        </section>

        <.how_it_works :if={!@current_user} card={false} class="mt-6 xl:hidden" />

        <:aside :if={!@current_user}>
          <.how_it_works />
        </:aside>
      </.page>

      <.dialog
        :if={@live_action == :new}
        id="new-room"
        show
        on_cancel={JS.patch(~p"/")}
        size="wide"
      >
        <:title>Open a room</:title>
        <.form
          for={@form}
          id="new-room-form"
          phx-change="validate"
          phx-submit="create"
          class="flex flex-col gap-5"
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
            placeholder="What is this room about? Optional."
            rows="2"
            maxlength={Room.topic_max()}
          />
          <.choice_cards
            field={@form[:visibility]}
            label="Visibility"
            options={[
              %{
                value: "public",
                title: "Listed",
                description: "Shown in the directory and found by its tags.",
                icon: "lucide-signpost"
              },
              %{
                value: "unlisted",
                title: "Unlisted",
                description: "Left out of the directory. Anyone with the link can still read it.",
                icon: "lucide-link"
              }
            ]}
          />
          <div :if={@form[:visibility].value != "unlisted"} class="flex flex-col gap-1.5">
            <.label for="new-room-tags-input">Tags</.label>
            <.tag_input
              id="new-room-tags"
              name="room[tags]"
              labels={@tag_labels}
              fixed={[Tag.auto_label()]}
              suggestions={@tag_suggestions}
              max={Tag.max_custom_labels()}
            />
            <p class="text-xs text-muted-foreground">
              Listed rooms are tagged "room" automatically.
            </p>
            <.error :for={{msg, _} <- Keyword.get_values(@form.errors, :tags)}>{msg}</.error>
          </div>
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

  # The three tags a card shows: the active filter first when the room carries
  # it (so a filtered list never hides the reason a room is listed), then the
  # most-used; the rest become a "+n".
  # the automatic `room` label is left out (every listed room carries it; the
  # room page and the dialog still show it, where the contract is explained)
  defp card_tags(tags, filter) do
    tags = Enum.reject(tags, &(&1.label == Tag.auto_label()))
    {matching, others} = Enum.split_with(tags, &(&1.label == filter))
    shown = Enum.take(matching ++ others, 3)
    {shown, length(tags) - length(shown)}
  end

  attr :tags, :list, required: true, doc: "`[{label, rooms}]` from `Directory.popular_tags/1`"
  attr :filter, :string, default: nil, doc: "the selected label, if any"
  attr :class, :any, default: nil

  # The popular-tag chips; a click toggles the directory filter.
  defp tag_chips(assigns) do
    ~H"""
    <div class={["flex gap-1.5", @class]}>
      <.tag
        :for={{label, _rooms} <- @tags}
        label={label}
        size="sm"
        selected={@filter == label}
        phx-click={JS.patch(if(@filter == label, do: ~p"/", else: ~p"/?tag=#{label}"))}
      />
    </div>
    """
  end

  attr :card, :boolean,
    default: true,
    doc: "a card (desktop right column) or a plain footer section with a rule above"

  attr :class, :any, default: nil

  # The explainer: a card in the right column from `xl`; below it, a plain
  # section closing the page, with a rule above to mark where the content ends.
  defp how_it_works(%{card: true} = assigns) do
    ~H"""
    <.card class={["gap-4 py-5", @class]}>
      <.card_header>
        <.section_title class="text-xl">How it works</.section_title>
      </.card_header>
      <.card_content class="flex flex-col gap-3 text-sm text-muted-foreground">
        <.how_it_works_points />
      </.card_content>
    </.card>
    """
  end

  defp how_it_works(assigns) do
    ~H"""
    <section class={["flex flex-col gap-4 border-t border-border pt-8", @class]}>
      <.section_title class="text-xl">How it works</.section_title>
      <div class="flex flex-col gap-3 text-sm text-muted-foreground">
        <.how_it_works_points />
      </div>
    </section>
    """
  end

  defp how_it_works_points(assigns) do
    ~H"""
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
    """
  end

  attr :room, Room, required: true
  attr :creator, :map, required: true, doc: "the creator's profile"
  attr :online, :map, default: nil, doc: "signed-in presence: `%{users, tabs}`"
  attr :viewers, :integer, default: 0, doc: "everyone with the room open, signed in or not"

  attr :tags, :list,
    default: [],
    doc: "`Directory.tags_of/1` result; three are shown, the rest counted"

  attr :filter, :string,
    default: nil,
    doc: "the active tag filter, always shown when the room has it"

  defp room_card(assigns) do
    ref = Room.ref(assigns.room)
    %{users: users, tabs: tabs} = assigns.online || %{users: 0, tabs: 0}
    {shown, hidden} = card_tags(assigns.tags, assigns.filter)

    assigns =
      assign(assigns,
        member_count: Directory.member_count(ref),
        shown_tags: shown,
        hidden_tags: hidden,
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
              <.icon name="lucide-door-closed" class="size-3" /> Closed
            </.badge>
            <span
              :if={@room.visibility == "unlisted" and not Room.closed?(@room)}
              class="inline-flex shrink-0 items-center gap-1 px-2 py-0.5 text-xs font-medium"
            >
              <.icon name="lucide-link" class="size-3" /> Unlisted
            </span>
          </div>
          <.card_description :if={@room.topic} class="line-clamp-2">{@room.topic}</.card_description>
          <div :if={@shown_tags != []} class="flex flex-wrap items-center gap-1.5 pt-1">
            <.tag
              :for={t <- @shown_tags}
              label={t.label}
              count={t.count}
              size="sm"
              selected={t.label == @filter}
              static
            />
            <span :if={@hidden_tags > 0} class="text-xs text-muted-foreground" title="more tags">
              +{@hidden_tags}
            </span>
          </div>
        </.card_header>
        <.card_footer class="justify-between gap-3 text-xs text-muted-foreground">
          <span class="flex min-w-0 items-center gap-2">
            <.avatar src={@creator.avatar_url} name={@creator.name} pubky={@creator.pubky} size="xs" />
            <span class="truncate">{@creator.name}</span>
          </span>
          <span class="flex shrink-0 items-center gap-3">
            <span class="flex items-center gap-1" title="Members">
              <.icon name="lucide-users" class="size-3.5" /> {@member_count}
            </span>
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
            <span :if={@activity}>{Format.relative(@activity)}</span>
          </span>
        </.card_footer>
      </.card>
    </.link>
    """
  end
end

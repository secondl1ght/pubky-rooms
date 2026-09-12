defmodule PubkyRoomsWeb.RoomLive do
  @moduledoc """
  A room: live messages, composer, members.

  The LiveView attaches to the room's `PubkyRooms.Rooms.RoomServer`, renders
  its history into a stream, and applies broadcast room events. Sending a
  message renders it immediately as *pending*; when the author's homeserver
  announces the file (its PUT event), the room server confirms it and the
  message flips to *stored on your homeserver*.
  """
  use PubkyRoomsWeb, :live_view

  alias PubkyRooms.{Ids, Profiles, Rooms}
  alias PubkyRooms.Rooms.{Message, RoomServer}
  alias PubkyRoomsWeb.{Format, Presence}

  # a viewer is shown as typing for this long after their last keystroke event
  @typing_ttl 4_000
  @typing_throttle 2_000

  @impl true
  def mount(%{"creator" => creator, "room_id" => room_id}, _session, socket) do
    if Ids.valid_z32?(creator) and Ids.valid_id?(room_id) do
      ref = {creator, room_id}

      socket =
        socket
        |> assign(
          ref: ref,
          creator: creator,
          room_id: room_id,
          page_title: "Room",
          status: :loading,
          room: nil,
          members: [],
          profiles: %{},
          is_member: false,
          failed: %{},
          sent: %{},
          unreachable: [],
          polled: [],
          live_unavailable: [],
          room_pid: nil,
          room_monitor: nil,
          composer: composer_form(),
          joining: false,
          online: %{},
          typing: %{},
          typing_timer: nil,
          last_typing_at: nil
        )
        |> stream_configure(:messages, dom_id: &dom_id/1)
        |> stream(:messages, [])

      if connected?(socket) do
        Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(ref))
        Phoenix.PubSub.subscribe(PubkyRooms.PubSub, Rooms.typing_topic(ref))
        {:ok, socket |> attach() |> track_presence()}
      else
        {:ok, socket}
      end
    else
      {:ok, socket |> put_flash(:error, "That room link is not valid.") |> redirect(to: ~p"/")}
    end
  end

  # Starts the room server if needed, attaches as a viewer and monitors it: if
  # the server crashes, `{:DOWN, …}` below re-attaches (which restarts it).
  defp attach(%{assigns: %{ref: ref}} = socket) do
    case RoomServer.ensure(ref) do
      {:ok, pid} ->
        {:ok, snapshot} = RoomServer.attach(ref)

        socket
        |> monitor_room(pid)
        |> apply_snapshot(snapshot)

      {:error, reason} ->
        assign(socket, status: {:error, reason})
    end
  end

  defp monitor_room(socket, pid) do
    if socket.assigns[:room_pid] == pid do
      socket
    else
      if ref = socket.assigns[:room_monitor], do: Process.demonitor(ref, [:flush])
      assign(socket, room_pid: pid, room_monitor: Process.monitor(pid))
    end
  end

  defp apply_snapshot(socket, %{status: :ready, table: table} = snapshot) do
    socket
    |> assign_room(snapshot)
    |> stream(:messages, RoomServer.history(table), reset: true)
  end

  defp apply_snapshot(socket, snapshot), do: assign_room(socket, snapshot)

  defp assign_room(socket, %{status: status, room: room, members: members} = snapshot) do
    user = socket.assigns.current_user

    socket
    |> assign(status: status, room: room, page_title: (room && room.name) || "Room")
    |> assign_members(members)
    |> assign(is_member: user != nil and user.pubky in members)
    |> assign(
      unreachable: Map.get(snapshot, :unreachable, []),
      polled: Map.get(snapshot, :polled, []),
      live_unavailable: Map.get(snapshot, :live_unavailable, [])
    )
  end

  defp assign_members(socket, members) do
    profiles = Map.new(members, &{&1, Profiles.get(&1)})
    assign(socket, members: members, profiles: Map.merge(socket.assigns.profiles, profiles))
  end

  # Signed-in viewers are tracked in the room's presence; anonymous ones only
  # subscribe. `online` maps z32 → number of open tabs.
  defp track_presence(%{assigns: %{ref: ref, current_user: user}} = socket) do
    topic = Presence.room_topic(ref)
    Presence.subscribe(topic)
    if user, do: Presence.track_room(ref, user)
    online = topic |> Presence.online() |> Map.new(fn {z32, metas} -> {z32, length(metas)} end)
    Enum.reduce(Map.keys(online), assign(socket, online: online), &ensure_profile(&2, &1))
  end

  # ── events from the browser ────────────────────────────────────────────────

  @impl true
  def handle_event("send", %{"message" => %{"content" => content}}, socket) do
    %{current_user: user, sid: sid, ref: ref} = socket.assigns

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "Sign in to chat.")}

      not socket.assigns.is_member ->
        {:noreply, put_flash(socket, :error, "Join the room to chat.")}

      true ->
        case Rooms.prepare_message(sid, user.pubky, ref, content) do
          {:ok, msg} ->
            {:noreply,
             socket
             |> stop_typing()
             |> stream_insert(:messages, msg)
             |> assign(
               composer: composer_form(),
               sent: Map.put(socket.assigns.sent, msg.key, msg)
             )
             |> push_event("composer:clear", %{})
             |> start_async({:publish, msg.key}, fn -> Rooms.publish_message(sid, msg) end)}

          {:error, reason} ->
            {:noreply, assign(socket, composer: composer_form(content, Rooms.explain(reason)))}
        end
    end
  end

  def handle_event("retry", %{"id" => id}, %{assigns: %{failed: failed, sid: sid}} = socket) do
    case Map.fetch(failed, id) do
      {:ok, msg} ->
        msg = %{msg | state: :pending, fail_reason: nil}

        {:noreply,
         socket
         |> assign(
           failed: Map.delete(failed, id),
           sent: Map.put(socket.assigns.sent, msg.key, msg)
         )
         |> stream_insert(:messages, msg)
         |> start_async({:publish, msg.key}, fn -> Rooms.retry_message(sid, msg) end)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("discard", %{"id" => id}, %{assigns: %{failed: failed}} = socket) do
    case Map.fetch(failed, id) do
      {:ok, msg} ->
        {:noreply,
         socket |> assign(failed: Map.delete(failed, id)) |> stream_delete(:messages, msg)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("retry_history", _params, socket) do
    RoomServer.retry_history(socket.assigns.ref)
    {:noreply, socket}
  end

  # The composer reports keystrokes; at most one broadcast every 2 s per viewer.
  def handle_event("typing", _params, %{assigns: %{current_user: %{pubky: z32}}} = socket) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_typing_at

    if socket.assigns.is_member and (is_nil(last) or now - last >= @typing_throttle) do
      Rooms.broadcast_typing(socket.assigns.ref, z32, true)
      {:noreply, assign(socket, last_typing_at: now)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("typing", _params, socket), do: {:noreply, socket}
  def handle_event("stop_typing", _params, socket), do: {:noreply, stop_typing(socket)}

  def handle_event("join", _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, redirect(socket, to: ~p"/login?return_to=#{room_path(socket)}")}
  end

  def handle_event(
        "join",
        _params,
        %{assigns: %{current_user: user, sid: sid, ref: ref}} = socket
      ) do
    {:noreply,
     socket
     |> assign(joining: true)
     |> start_async(:join, fn -> Rooms.join(sid, user.pubky, ref) end)}
  end

  def handle_event(
        "leave",
        _params,
        %{assigns: %{current_user: user, sid: sid, ref: ref}} = socket
      ) do
    {:noreply,
     socket
     |> assign(joining: true)
     |> start_async(:leave, fn -> Rooms.leave(sid, user.pubky, ref) end)}
  end

  # ── async results ──────────────────────────────────────────────────────────

  @impl true
  def handle_async({:publish, _key}, {:ok, :ok}, socket), do: {:noreply, socket}
  def handle_async({:publish, _key}, {:ok, {:ok, _msg}}, socket), do: {:noreply, socket}

  def handle_async({:publish, key}, {:ok, {:error, :unauthorized}}, socket) do
    {:noreply,
     socket
     |> fail_message(key, :unauthorized)
     |> put_flash(:error, Rooms.explain(:unauthorized))}
  end

  def handle_async({:publish, key}, {:ok, {:error, reason}}, socket) do
    {:noreply, fail_message(socket, key, reason)}
  end

  def handle_async({:publish, key}, {:exit, reason}, socket) do
    {:noreply, fail_message(socket, key, {:unexpected, reason})}
  end

  def handle_async(:join, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(joining: false, is_member: true)
     |> put_flash(:success, "You joined the room.")}
  end

  def handle_async(:join, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(joining: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  def handle_async(:leave, {:ok, :ok}, socket) do
    {:noreply,
     socket |> assign(joining: false, is_member: false) |> put_flash(:info, "You left the room.")}
  end

  def handle_async(:leave, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(joining: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  def handle_async(_name, {:exit, reason}, socket) do
    {:noreply, socket |> assign(joining: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  # ── room events ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:room_event, ref, event}, %{assigns: %{ref: ref}} = socket) do
    {:noreply, apply_room_event(socket, event)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{room_monitor: ref}} = socket
      ) do
    {:noreply, socket |> assign(room_pid: nil, room_monitor: nil, status: :loading) |> attach()}
  end

  def handle_info({:profile_updated, z32, profile}, socket) do
    if Map.has_key?(socket.assigns.profiles, z32),
      do: {:noreply, assign(socket, profiles: Map.put(socket.assigns.profiles, z32, profile))},
      else: {:noreply, socket}
  end

  def handle_info({:presence, {:join, %{key: z32, metas: metas}}}, socket) do
    online = Map.put(socket.assigns.online, z32, length(metas))
    {:noreply, socket |> assign(online: online) |> ensure_profile(z32)}
  end

  def handle_info({:presence, {:leave, %{key: z32, metas: []}}}, socket) do
    {:noreply,
     assign(socket,
       online: Map.delete(socket.assigns.online, z32),
       typing: Map.delete(socket.assigns.typing, z32)
     )}
  end

  def handle_info({:presence, {:leave, %{key: z32, metas: metas}}}, socket) do
    {:noreply, assign(socket, online: Map.put(socket.assigns.online, z32, length(metas)))}
  end

  def handle_info({:typing, z32, _}, %{assigns: %{current_user: %{pubky: z32}}} = socket),
    do: {:noreply, socket}

  def handle_info({:typing, z32, true}, socket) do
    until = System.monotonic_time(:millisecond) + @typing_ttl

    {:noreply,
     socket
     |> assign(typing: Map.put(socket.assigns.typing, z32, until))
     |> ensure_profile(z32)
     |> schedule_typing_prune()}
  end

  def handle_info({:typing, z32, false}, socket),
    do: {:noreply, assign(socket, typing: Map.delete(socket.assigns.typing, z32))}

  def handle_info(:prune_typing, socket) do
    now = System.monotonic_time(:millisecond)
    typing = socket.assigns.typing |> Enum.reject(fn {_, until} -> until <= now end) |> Map.new()
    {:noreply, socket |> assign(typing: typing, typing_timer: nil) |> schedule_typing_prune()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_typing_prune(%{assigns: %{typing: typing, typing_timer: nil}} = socket)
       when map_size(typing) > 0,
       do: assign(socket, typing_timer: Process.send_after(self(), :prune_typing, 1_000))

  defp schedule_typing_prune(socket), do: socket

  defp stop_typing(%{assigns: %{last_typing_at: nil}} = socket), do: socket

  defp stop_typing(%{assigns: %{current_user: %{pubky: z32}, ref: ref}} = socket) do
    Rooms.broadcast_typing(ref, z32, false)
    assign(socket, last_typing_at: nil)
  end

  defp stop_typing(socket), do: socket

  defp apply_room_event(socket, :ready), do: attach(socket)

  defp apply_room_event(socket, {:message_upserted, %Message{} = msg}) do
    socket
    |> assign(
      failed: Map.delete(socket.assigns.failed, dom_id(msg)),
      sent: Map.delete(socket.assigns.sent, msg.key),
      typing: Map.delete(socket.assigns.typing, msg.author)
    )
    |> ensure_profile(msg.author)
    |> stream_insert(:messages, msg)
  end

  defp apply_room_event(socket, {:message_deleted, key}) do
    stream_delete_by_dom_id(socket, :messages, dom_id(key))
  end

  defp apply_room_event(socket, {:message_failed, key, reason}),
    do: fail_message(socket, key, reason)

  defp apply_room_event(socket, {:member_joined, z32}) do
    socket
    |> assign_members(Enum.uniq([z32 | socket.assigns.members]))
    |> maybe_set_member(z32, true)
  end

  defp apply_room_event(socket, {:member_left, z32}) do
    socket
    |> assign_members(List.delete(socket.assigns.members, z32))
    |> maybe_set_member(z32, false)
  end

  defp apply_room_event(socket, {:room_updated, room}),
    do: assign(socket, room: room, page_title: room.name)

  defp apply_room_event(socket, :room_closed) do
    socket |> assign(status: :closed) |> put_flash(:info, "The creator closed this room.")
  end

  defp apply_room_event(socket, {:unavailable, status}), do: assign(socket, status: status)
  defp apply_room_event(socket, {:unreachable, members}), do: assign(socket, unreachable: members)
  defp apply_room_event(socket, {:polled, members}), do: assign(socket, polled: members)

  defp apply_room_event(socket, {:live_unavailable, members}),
    do: assign(socket, live_unavailable: members)

  defp apply_room_event(socket, _other), do: socket

  defp maybe_set_member(%{assigns: %{current_user: %{pubky: z32}}} = socket, z32, value),
    do: assign(socket, is_member: value)

  defp maybe_set_member(socket, _z32, _value), do: socket

  defp ensure_profile(socket, z32) do
    if Map.has_key?(socket.assigns.profiles, z32),
      do: socket,
      else: assign(socket, profiles: Map.put(socket.assigns.profiles, z32, Profiles.get(z32)))
  end

  # Stream items cannot be read back, so messages sent from this LiveView are
  # kept in `sent` until confirmed; a failure re-renders them from there.
  defp fail_message(socket, key, reason) do
    case Map.get(socket.assigns.sent, key) do
      nil ->
        socket

      msg ->
        msg = %{msg | state: :failed, fail_reason: reason}

        socket
        |> assign(
          failed: Map.put(socket.assigns.failed, dom_id(key), msg),
          sent: Map.delete(socket.assigns.sent, key)
        )
        |> stream_insert(:messages, msg)
    end
  end

  defp composer_form(content \\ "", error \\ nil) do
    errors = if error, do: [content: {error, []}], else: []
    to_form(%{"content" => content}, as: :message, errors: errors)
  end

  defp room_path(%{assigns: assigns}), do: room_path(assigns)
  defp room_path(%{creator: c, room_id: id}), do: ~p"/r/#{c}/#{id}"

  defp dom_id(%Message{key: key}), do: dom_id(key)
  defp dom_id({msg_id, author}), do: "msg-#{author}-#{msg_id}"

  # ── rendering ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} back={~p"/"}>
      <.container class="flex h-[calc(100dvh-5rem)] flex-col gap-3 pb-24 lg:h-[calc(100dvh-9rem)] lg:pb-6">
        <.room_header
          room={@room}
          status={@status}
          members={@members}
          online_count={map_size(@online)}
          is_member={@is_member}
          current_user={@current_user}
          joining={@joining}
          creator={@creator}
          room_id={@room_id}
        />

        <div class="flex min-h-0 flex-1 gap-6">
          <div class="flex min-w-0 flex-1 flex-col overflow-hidden rounded-xl bg-card">
            <div
              :if={@unreachable != []}
              class="flex flex-wrap items-center justify-between gap-2 border-b border-border/60 bg-destructive/10 px-4 py-2 text-sm text-secondary-foreground"
              role="status"
            >
              <span class="flex items-center gap-2">
                <.icon name="lucide-cloud-off" class="size-4 text-destructive" />
                History from {length(@unreachable)}
                {if length(@unreachable) == 1, do: "member", else: "members"} could not be loaded from their homeserver.
              </span>
              <.button variant="ghost" size="sm" phx-click="retry_history">
                <.icon name="lucide-refresh-cw" class="size-4" /> Retry
              </.button>
            </div>
            <div
              :if={@live_unavailable != []}
              id="live-unavailable"
              class="flex items-center gap-2 border-b border-border/60 bg-white/[0.03] px-4 py-2 text-sm text-secondary-foreground"
              role="status"
            >
              <.icon name="lucide-wifi-off" class="size-4 text-muted-foreground" />
              Live updates from {members_phrase(length(@live_unavailable))} are unavailable right now
              (their homeserver's event stream is down); new messages appear once it is back.
            </div>
            <div
              :if={@polled != []}
              id="polled-members"
              class="flex items-center gap-2 border-b border-border/60 bg-white/[0.03] px-4 py-2 text-sm text-secondary-foreground"
              role="status"
            >
              <.icon name="lucide-timer" class="size-4 text-muted-foreground" />
              This room is over the live-subscription budget: {members_phrase(length(@polled))} are checked for new messages about once a minute instead of live.
            </div>
            <div
              id="messages"
              phx-update="stream"
              phx-hook="ScrollToBottom"
              class="flex flex-1 flex-col gap-1 overflow-x-hidden overflow-y-auto px-4 py-4 sm:px-6"
              aria-live="polite"
            >
              <div
                id="messages-empty"
                class="hidden only:flex flex-1 flex-col items-center justify-center gap-2 py-16 text-center text-sm text-muted-foreground"
              >
                <.icon :if={@status == :ready} name="lucide-message-square-dashed" class="size-8" />
                <.spinner :if={@status in [:loading, :bootstrapping]} class="size-6" />
                <span :if={@status == :ready}>No messages yet. Say hello.</span>
                <span :if={@status in [:loading, :bootstrapping]}>Loading the room from its members' homeservers…</span>
                <span :if={@status == :not_found}>This room does not exist on its creator's homeserver.</span>
                <span :if={@status == :closed}>This room was closed by its creator.</span>
                <span :if={match?({:error, _}, @status)}>The creator's homeserver could not be reached. Try again later.</span>
              </div>
              <.message_row
                :for={{id, msg} <- @streams.messages}
                id={id}
                msg={msg}
                profile={Map.get(@profiles, msg.author) || Profiles.get(msg.author)}
                own={@current_user != nil && @current_user.pubky == msg.author}
              />
            </div>

            <.typing_line typing={@typing} profiles={@profiles} />

            <div class="shrink-0 border-t border-border/60 p-3 sm:p-4">
              <%= cond do %>
                <% is_nil(@current_user) -> %>
                  <div class="flex flex-wrap items-center justify-between gap-3 text-sm text-muted-foreground">
                    <span>Sign in with Pubky Ring to chat.</span>
                    <.button navigate={~p"/login?return_to=#{room_path(assigns)}"}>
                      <.icon name="lucide-key-round" class="size-4" /> Sign in
                    </.button>
                  </div>
                <% not @is_member -> %>
                  <div class="flex flex-wrap items-center justify-between gap-3 text-sm text-muted-foreground">
                    <span>Join the room to chat. Joining writes a small marker file to your homeserver.</span>
                    <.button variant="brand" phx-click="join" disabled={@joining or @status != :ready}>
                      <.spinner :if={@joining} class="size-4" />
                      <.icon :if={!@joining} name="lucide-log-in" class="size-4" /> Join room
                    </.button>
                  </div>
                <% true -> %>
                  <.form for={@composer} id="composer" phx-submit="send" class="flex flex-col gap-2">
                    <div class="flex items-end gap-3 rounded-md border border-dashed border-input px-4 py-3 focus-within:border-ring">
                      <.avatar
                        src={@current_user.avatar_url}
                        name={@current_user.name}
                        pubky={@current_user.pubky}
                        size="md"
                        class="mb-0.5"
                      />
                      <.input
                        field={@composer[:content]}
                        type="textarea"
                        variant="inline"
                        id="composer-input"
                        placeholder="Say something…"
                        rows="1"
                        maxlength={Message.content_max()}
                        wrapper_class="flex-1"
                        phx-hook="Composer"
                        data-typing-events
                        disabled={@status != :ready}
                        autocomplete="off"
                      />
                      <.button
                        variant="brand"
                        size="icon"
                        type="submit"
                        aria-label="Send"
                        disabled={@status != :ready}
                      >
                        <.icon name="lucide-send" class="size-4" />
                      </.button>
                    </div>
                    <p class="px-1 text-xs text-muted-foreground">
                      Enter to send, Shift+Enter for a new line. Stored at
                      <code class="text-[11px]">pubky://{Profiles.short_key(@current_user.pubky)}/pub/pubky-rooms/…</code>
                    </p>
                  </.form>
              <% end %>
            </div>
          </div>

          <aside class="hidden w-64 shrink-0 flex-col gap-4 xl:flex">
            <.card class="gap-3 py-5">
              <.card_header>
                <.section_title class="text-xl">Members · {length(@members)}</.section_title>
                <p class="text-xs text-muted-foreground">
                  <span class="mr-1 inline-block size-2 rounded-full bg-[#00FF5D] align-middle"></span>
                  {map_size(@online)} online
                </p>
              </.card_header>
              <.card_content class="flex flex-col gap-3">
                <div
                  :for={z32 <- sort_members(@members, @online, @profiles)}
                  class="flex items-center gap-3"
                >
                  <.avatar
                    src={profile_of(@profiles, z32).avatar_url}
                    name={profile_of(@profiles, z32).name}
                    pubky={z32}
                    size="md"
                    online={Map.has_key?(@online, z32)}
                  />
                  <span class={[
                    "min-w-0 flex-1 truncate text-sm font-semibold",
                    !Map.has_key?(@online, z32) && "text-muted-foreground"
                  ]}>
                    {profile_of(@profiles, z32).name}
                  </span>
                  <.badge :if={z32 == @creator} variant="brand-soft">creator</.badge>
                  <span
                    :if={z32 in @unreachable}
                    class="tooltip text-destructive"
                    data-tip="Homeserver unreachable"
                    aria-label="Homeserver unreachable"
                  >
                    <.icon name="lucide-cloud-off" class="size-4" />
                  </span>
                  <span
                    :if={z32 in @live_unavailable and z32 not in @unreachable}
                    class="tooltip text-muted-foreground"
                    data-tip="Live updates unavailable, retrying"
                    aria-label="Live updates unavailable, retrying"
                  >
                    <.icon name="lucide-wifi-off" class="size-4" />
                  </span>
                  <span
                    :if={z32 in @polled}
                    class="tooltip text-muted-foreground"
                    data-tip="Checked once a minute (over the live budget)"
                    aria-label="Checked once a minute (over the live budget)"
                  >
                    <.icon name="lucide-timer" class="size-4" />
                  </span>
                </div>
              </.card_content>
            </.card>
            <.card :if={visitors(@online, @members) != []} class="gap-3 py-5">
              <.card_header>
                <.section_title class="text-xl">Also here</.section_title>
                <p class="text-xs text-muted-foreground">Signed in, not (yet) members</p>
              </.card_header>
              <.card_content class="flex flex-col gap-3">
                <div :for={z32 <- visitors(@online, @members)} class="flex items-center gap-3">
                  <.avatar
                    src={profile_of(@profiles, z32).avatar_url}
                    name={profile_of(@profiles, z32).name}
                    pubky={z32}
                    size="md"
                    online
                  />
                  <span class="min-w-0 flex-1 truncate text-sm font-semibold">
                    {profile_of(@profiles, z32).name}
                  </span>
                </div>
              </.card_content>
            </.card>
          </aside>
        </div>
      </.container>
    </Layouts.app>
    """
  end

  defp profile_of(profiles, z32), do: Map.get(profiles, z32) || Profiles.fallback(z32)

  defp members_phrase(1), do: "1 member"
  defp members_phrase(n), do: "#{n} members"

  # online members first, then by name
  defp sort_members(members, online, profiles) do
    Enum.sort_by(members, fn z32 ->
      {if(Map.has_key?(online, z32), do: 0, else: 1),
       String.downcase(profile_of(profiles, z32).name)}
    end)
  end

  defp visitors(online, members),
    do: online |> Map.keys() |> Enum.reject(&(&1 in members)) |> Enum.sort()

  attr :typing, :map, required: true, doc: "z32 → expiry"
  attr :profiles, :map, required: true

  defp typing_line(assigns) do
    names =
      assigns.typing
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(&profile_of(assigns.profiles, &1).name)

    text =
      case names do
        [] -> nil
        [a] -> "#{a} is typing…"
        [a, b] -> "#{a} and #{b} are typing…"
        [a, b, _ | _] -> "#{a}, #{b} and others are typing…"
      end

    assigns = assign(assigns, text: text)

    ~H"""
    <div
      id="typing"
      class="h-5 shrink-0 truncate px-4 text-xs text-muted-foreground sm:px-6"
      aria-live="polite"
    >
      <span :if={@text} class="inline-flex items-center gap-1.5">
        <span class="inline-flex gap-0.5" aria-hidden="true">
          <span class="size-1 animate-bounce rounded-full bg-muted-foreground [animation-delay:-0.3s]"></span>
          <span class="size-1 animate-bounce rounded-full bg-muted-foreground [animation-delay:-0.15s]"></span>
          <span class="size-1 animate-bounce rounded-full bg-muted-foreground"></span>
        </span>
        {@text}
      </span>
    </div>
    """
  end

  attr :room, :any, required: true
  attr :status, :any, required: true
  attr :members, :list, required: true
  attr :online_count, :integer, required: true
  attr :is_member, :boolean, required: true
  attr :current_user, :any, required: true
  attr :joining, :boolean, required: true
  attr :creator, :string, required: true
  attr :room_id, :string, required: true

  defp room_header(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-3">
      <div class="flex min-w-0 items-center gap-3">
        <.link
          navigate={~p"/"}
          class="hidden size-9 shrink-0 items-center justify-center rounded-full text-muted-foreground hover:bg-white/5 hover:text-foreground lg:flex"
          aria-label="Back to rooms"
        >
          <.icon name="lucide-arrow-left" class="size-5" />
        </.link>
        <div class="flex min-w-0 flex-col">
          <h1 class="truncate text-xl font-bold leading-tight">
            {if @room, do: @room.name, else: "Room"}
          </h1>
          <p :if={@room && @room.topic} class="truncate text-sm text-muted-foreground">
            {@room.topic}
          </p>
        </div>
        <.badge
          :if={@room && @room.visibility == "unlisted"}
          variant="outline"
          class="hidden sm:inline-flex"
        >
          <.icon name="lucide-link" class="size-3" /> unlisted
        </.badge>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <span
          class="hidden items-center gap-1 text-xs text-muted-foreground sm:flex"
          title="Members"
        >
          <.icon name="lucide-users" class="size-3.5" /> {length(@members)}
        </span>
        <span
          class="flex items-center gap-1.5 text-xs text-muted-foreground"
          title="Signed-in people in the room right now"
        >
          <span class="inline-block size-2 rounded-full bg-[#00FF5D]"></span>
          <span id="online-count">{@online_count} online</span>
        </span>
        <.button
          variant="secondary"
          size="icon"
          id="copy-room-link"
          phx-hook="Clipboard"
          data-copy={url(~p"/r/#{@creator}/#{@room_id}")}
          aria-label="Copy room link"
          data-tip="Copy link"
          class="tooltip"
        >
          <.icon name="lucide-link" class="size-4" />
        </.button>
        <.button
          :if={@is_member && @current_user && @current_user.pubky != @creator}
          variant="ghost"
          size="sm"
          phx-click="leave"
          disabled={@joining}
        >
          Leave
        </.button>
      </div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :msg, Message, required: true
  attr :profile, :map, required: true
  attr :own, :boolean, default: false

  defp message_row(assigns) do
    ~H"""
    <article
      id={@id}
      class="group flex gap-3 rounded-lg px-2 py-2 transition-colors hover:bg-white/[0.03]"
    >
      <.avatar
        src={@profile.avatar_url}
        name={@profile.name}
        pubky={@msg.author}
        size="default"
        class="mt-0.5"
      />
      <div class="flex min-w-0 flex-1 flex-col gap-0.5">
        <div class="flex items-baseline gap-2">
          <span class="truncate text-sm font-bold leading-5">{@profile.name}</span>
          <time
            datetime={Format.iso(@msg.created_at)}
            class="text-xs text-muted-foreground"
            title={Format.iso(@msg.created_at)}
          >
            {Format.clock(@msg.created_at)}
          </time>
          <span :if={@msg.edited_at} class="text-xs text-muted-foreground">(edited)</span>
        </div>
        <p class={[
          "whitespace-pre-wrap break-words text-base text-secondary-foreground",
          @msg.state == :pending && "opacity-60"
        ]}>
          {@msg.content}
        </p>
        <div
          :if={@msg.state == :failed}
          class="mt-1 flex flex-wrap items-center gap-2 text-xs text-destructive"
        >
          <.icon name="lucide-circle-alert" class="size-3.5" />
          <span>Not stored: {Rooms.explain(@msg.fail_reason)}</span>
          <.button variant="destructive-soft" size="sm" phx-click="retry" phx-value-id={@id}>Retry</.button>
          <.button variant="ghost" size="sm" phx-click="discard" phx-value-id={@id}>Discard</.button>
        </div>
      </div>
      <div :if={@own} class="flex shrink-0 items-start pt-1">
        <span
          :if={@msg.state == :pending}
          class="tooltip text-muted-foreground"
          data-tip="Sending to your homeserver…"
        >
          <.icon name="lucide-clock" class="size-4" />
        </span>
        <span
          :if={@msg.state == :confirmed}
          class="tooltip text-brand"
          data-tip="Stored on your homeserver"
        >
          <.icon name="lucide-circle-check" class="size-4" />
        </span>
        <span :if={@msg.state == :failed} class="text-destructive">
          <.icon name="lucide-circle-x" class="size-4" />
        </span>
      </div>
    </article>
    """
  end
end

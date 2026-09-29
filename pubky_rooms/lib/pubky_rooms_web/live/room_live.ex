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

  alias PubkyRooms.{Ids, Mutes, Profiles, Rooms}
  alias PubkyRooms.Rooms.{Ban, Directory, Message, Paths, Reaction, Room, RoomServer}
  alias PubkyRooms.Tags.Tag
  alias PubkyRoomsWeb.{Format, Linkify, Presence}

  # a viewer is shown as typing for this long after their last keystroke event
  @typing_ttl 4_000
  @typing_throttle 2_000
  @max_jump_rounds 10

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
          table: nil,
          members: [],
          profiles: %{},
          is_member: false,
          is_creator: false,
          bans: %{},
          banned?: false,
          banning: nil,
          ban_form: to_form(%{"reason" => ""}, as: :ban),
          settings_form: nil,
          saving: false,
          tags: [],
          tag_suggestions: [],
          muted: MapSet.new(),
          app_muted: MapSet.new(),
          mutes_known: true,
          members_open: false,
          failed: %{},
          sent: %{},
          unreachable: [],
          polled: [],
          live_unavailable: [],
          room_pid: nil,
          room_monitor: nil,
          composer: composer_form(),
          composer_mode: :new,
          joining: false,
          online: %{},
          viewers: 0,
          oldest_key: nil,
          has_more: false,
          loading_older: false,
          jump_target: nil,
          shown: MapSet.new(),
          newest_key: nil,
          jump_rounds: 0,
          typing: %{},
          typing_timer: nil,
          last_typing_at: nil
        )
        |> stream_configure(:messages, dom_id: &dom_id/1)
        |> stream(:messages, [])

      if connected?(socket) do
        Phoenix.PubSub.subscribe(PubkyRooms.PubSub, RoomServer.topic(ref))
        Phoenix.PubSub.subscribe(PubkyRooms.PubSub, Rooms.stats_topic(ref))
        Phoenix.PubSub.subscribe(PubkyRooms.PubSub, Rooms.typing_topic(ref))
        Directory.subscribe()
        Directory.refresh_nexus_tags(ref)
        {:ok, socket |> load_mutes() |> attach() |> track_presence() |> load_tags()}
      else
        {:ok, socket |> preview() |> load_tags()}
      end
    else
      {:ok, socket |> put_flash(:error, "That room link is not valid.") |> redirect(to: ~p"/")}
    end
  end

  # `/settings` opens the creator's settings dialog; anyone else is sent back.
  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :settings}} = socket) do
    cond do
      not connected?(socket) ->
        {:noreply, socket}

      socket.assigns.is_creator and socket.assigns.status == :ready ->
        {:noreply, assign(socket, settings_form: settings_form(socket))}

      true ->
        {:noreply, push_patch(socket, to: room_path(socket))}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, settings_form: nil)}

  defp settings_form(%{assigns: %{room: %Room{} = room}}),
    do:
      to_form(
        %{"name" => room.name, "topic" => room.topic || "", "visibility" => room.visibility},
        as: :room
      )

  defp settings_form(_socket),
    do: to_form(%{"name" => "", "topic" => "", "visibility" => "public"}, as: :room)

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

  # The disconnected first render (a hard refresh, a shared link) must not
  # flash placeholders that the connected render then replaces. A warm room
  # (its server is running, which a refresh guarantees) gives its whole
  # snapshot, messages included, so the first paint is the final one. A cold
  # room is painted from what the Directory knows (definition, members, tags,
  # who is online, the viewer's own membership); only messages and live status
  # wait for the room server. A room this node has never seen renders the
  # page-level loading state. Messages are never painted without the viewer's
  # mute lists: cached after any refresh, otherwise loaded here within a
  # second; if that times out the messages wait for the socket instead, so a
  # muted author never shows and then vanishes.
  defp preview(%{assigns: %{ref: ref}} = socket) do
    {socket, mutes_known?} = preview_mutes(socket)

    case RoomServer.peek(ref) do
      %{status: status} = snapshot when status in [:ready, :closed] and mutes_known? ->
        socket |> apply_snapshot(snapshot) |> assign_online(ref)

      _ ->
        preview_from_directory(socket)
    end
  end

  defp preview_mutes(%{assigns: %{current_user: %{pubky: z32}}} = socket) do
    case Mutes.fetch(z32, 1_000) do
      {:ok, %{own: own, app: app}} ->
        {assign(socket, muted: MapSet.union(own, app), app_muted: app, mutes_known: true), true}

      :timeout ->
        # the members list hides mute markers and actions until the socket knows
        {assign(socket, mutes_known: false), false}
    end
  end

  defp preview_mutes(socket), do: {socket, true}

  defp preview_from_directory(%{assigns: %{ref: ref}} = socket) do
    case Directory.get(ref) do
      nil ->
        socket

      %Room{} = room ->
        status = if Room.closed?(room), do: :closed, else: :loading

        socket
        |> assign_room(%{status: status, room: room, members: Directory.members_of(ref)})
        |> assign_online(ref)
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

  # Open rooms and closed archives both come with a table of messages.
  defp apply_snapshot(socket, %{status: status, table: table} = snapshot)
       when status in [:ready, :closed] do
    history = RoomServer.history(table)

    socket
    |> assign(
      table: table,
      oldest_key: history != [] && hd(history).key,
      has_more: Map.get(snapshot, :more?, false),
      loading_older: false
    )
    |> assign_room(snapshot)
    |> show_window(unmuted(socket, history))
  end

  defp apply_snapshot(socket, snapshot), do: assign_room(socket, snapshot)

  # The stream is a window onto the room's table, which is sorted by key. Rows
  # are appended in arrival order, so a row that belongs *before* the newest
  # one on screen (a rejoin backfill, a restored ban, a late history) cannot be
  # slotted in: the window is rebuilt from the table instead. `shown` and
  # `newest_key` are the bookkeeping that tells the two cases apart.
  defp show_window(socket, msgs) do
    socket
    |> assign(
      shown: MapSet.new(msgs, & &1.key),
      newest_key: Enum.max([nil | Enum.map(msgs, & &1.key)])
    )
    |> stream(:messages, msgs, reset: true)
  end

  defp note_shown(socket, msgs) do
    keys = Enum.map(msgs, & &1.key)

    assign(socket,
      shown: Enum.into(keys, socket.assigns.shown),
      newest_key: Enum.max([socket.assigns.newest_key | keys])
    )
  end

  defp forget_shown(socket, key),
    do: assign(socket, shown: MapSet.delete(socket.assigns.shown, key))

  # A message from the room: in place when it is already on screen or the newest.
  defp arrive(socket, %Message{key: key} = msg) do
    %{shown: shown, newest_key: newest} = socket.assigns

    if MapSet.member?(shown, key) or newest == nil or key > newest,
      do: socket |> stream_insert(:messages, msg) |> note_shown([msg]),
      else: rebuild_window(socket)
  end

  defp rebuild_window(%{assigns: %{table: nil}} = socket), do: socket

  defp rebuild_window(%{assigns: %{table: table, oldest_key: oldest}} = socket) do
    if :ets.info(table) == :undefined do
      socket
    else
      guards = if oldest, do: [{:>=, :"$1", {oldest}}], else: []
      stored = :ets.select(table, [{{:"$1", :"$2"}, guards, [:"$2"]}])
      stored_keys = MapSet.new(stored, & &1.key)

      # own messages still in flight or failed are not in the table yet
      local =
        (Map.values(socket.assigns.sent) ++ Map.values(socket.assigns.failed))
        |> Enum.reject(&MapSet.member?(stored_keys, &1.key))
        |> Enum.uniq_by(& &1.key)

      show_window(socket, unmuted(socket, Enum.sort_by(stored ++ local, & &1.key)))
    end
  end

  defp load_tags(socket), do: assign(socket, tags: Directory.tags_of(socket.assigns.ref))

  # Whether the viewer may write anything room-related right now: signed in,
  # the room is open (not closed, missing or loading) and they are not banned.
  # Posting and reacting additionally require membership (`can_post?/1`).
  defp can_write?(%{assigns: assigns}), do: can_write?(assigns)

  defp can_write?(%{current_user: user, status: status, banned?: banned?}),
    do: user != nil and status == :ready and not banned?

  # Unlisted rooms take no new tags (the lobby never shows them and Pubky App
  # would); tags added before a room was unlisted stay removable by their owners.
  defp can_tag?(%{room: %Room{visibility: "public"}} = assigns), do: can_write?(assigns)
  defp can_tag?(_assigns), do: false

  defp can_post?(%{assigns: assigns}), do: can_post?(assigns)
  defp can_post?(%{is_member: member?} = assigns), do: member? and can_write?(assigns)

  # Stream rows keep the gating they were rendered with (action buttons, chip
  # state), so whenever this viewer's permissions change — membership, ban,
  # the room closing — every row in the loaded window is re-inserted.
  defp refresh_rows(%{assigns: %{table: nil}} = socket), do: socket

  defp refresh_rows(%{assigns: %{table: table, oldest_key: oldest}} = socket) do
    if :ets.info(table) == :undefined do
      socket
    else
      guards = if oldest, do: [{:>=, :"$1", {oldest}}], else: []
      reinsert(socket, :ets.select(table, [{{:"$1", :"$2"}, guards, [:"$2"]}]))
    end
  end

  # Re-renders rows from the table: the ones on screen in place, any other
  # through the order check (a row the stream lacks must not just be appended,
  # and a muted author's rows must not slip back in).
  defp reinsert(socket, msgs) do
    socket
    |> unmuted(msgs)
    |> Enum.reduce(socket, fn msg, s ->
      if MapSet.member?(s.assigns.shown, msg.key),
        do: stream_insert(s, :messages, msg),
        else: arrive(s, msg)
    end)
  end

  defp in_window?(%{assigns: %{oldest_key: nil}}, _msg), do: true
  defp in_window?(%{assigns: %{oldest_key: oldest}}, %Message{key: key}), do: key >= oldest

  # Quotes are resolved at render time, so the loaded rows that reply to an
  # edited or deleted message are re-inserted to show the new text or the
  # missing state (stream rows never re-render on their own).
  defp refresh_replies(%{assigns: %{table: nil}} = socket, _key), do: socket

  defp refresh_replies(%{assigns: %{table: table, oldest_key: oldest}} = socket, {msg_id, author}) do
    if :ets.info(table) == :undefined do
      socket
    else
      guards = if oldest, do: [{:>=, :"$1", {oldest}}], else: []

      table
      |> :ets.select([{{:"$1", :"$2"}, guards, [:"$2"]}])
      |> Enum.filter(&replies_to?(&1, author, msg_id))
      |> then(&reinsert(socket, &1))
    end
  end

  defp replies_to?(%Message{reply_to: nil}, _author, _msg_id), do: false

  defp replies_to?(%Message{reply_to: uri}, author, msg_id),
    do: match?({:ok, {^author, _ref, ^msg_id}}, Paths.parse_message_uri(uri))

  # Mutes hide an author's messages from this viewer (see `PubkyRooms.Mutes`).
  defp unmuted(%{assigns: %{muted: muted}}, msgs),
    do: Enum.reject(msgs, &MapSet.member?(muted, &1.author))

  # Asks the room for the page before the oldest loaded message (one at a time).
  defp load_older_page(socket) do
    %{ref: ref, oldest_key: before, has_more: more?, loading_older: loading?} = socket.assigns

    if more? and not loading? and before do
      limit = Application.get_env(:pubky_rooms, :page_size, 50)

      socket
      |> assign(loading_older: true)
      |> start_async(:older, fn -> RoomServer.older(ref, before, limit) end)
    else
      socket
    end
  end

  defp prepend_older(socket, []), do: socket

  # Items are inserted one by one at index 0, so the batch goes in reversed.
  defp prepend_older(socket, [oldest | _] = msgs) do
    socket
    |> assign(oldest_key: oldest.key)
    |> stream(:messages, socket |> unmuted(msgs) |> Enum.reverse(), at: 0)
    |> note_shown(msgs)
  end

  defp jump_to(socket, {_msg_id, author} = key) do
    %{muted: muted, has_more: more?, oldest_key: oldest, loading_older: loading?} = socket.assigns

    cond do
      MapSet.member?(muted, author) ->
        put_flash(socket, :info, "That message is from someone you muted.")

      on_screen?(socket, key) ->
        push_event(socket, "scroll_to", %{id: dom_id(key)})

      more? and oldest != nil and not loading? ->
        socket |> assign(jump_target: key, jump_rounds: 0) |> load_older_page()

      true ->
        put_flash(socket, :info, "That message is no longer available.")
    end
  end

  # One more page arrived while jumping: done, keep going, or give up.
  defp continue_jump(socket, key, msgs, more?) do
    rounds = socket.assigns.jump_rounds + 1

    cond do
      on_screen?(socket, key) ->
        socket |> assign(jump_target: nil) |> push_event("scroll_to", %{id: dom_id(key)})

      more? and msgs != [] and rounds < @max_jump_rounds ->
        socket |> assign(jump_rounds: rounds) |> load_older_page()

      more? ->
        socket
        |> assign(jump_target: nil)
        |> put_flash(:error, "Earlier messages could not be loaded right now.")

      true ->
        socket
        |> assign(jump_target: nil)
        |> put_flash(:info, "That message is no longer available.")
    end
  end

  # Held by the room and inside the loaded window (so its row is in the DOM).
  defp on_screen?(%{assigns: %{oldest_key: oldest}} = socket, key),
    do: oldest != nil and key >= oldest and stored_message(socket, key) != nil

  defp parse_dom_id("msg-" <> rest) when byte_size(rest) == 66 do
    <<author::binary-size(52), "-", msg_id::binary-size(13)>> = rest

    if Ids.valid_z32?(author) and Ids.valid_id?(msg_id),
      do: {:ok, {msg_id, author}},
      else: :error
  end

  defp parse_dom_id(_id), do: :error

  # The viewer's mute lists (Rooms + Pubky App) are read before the history
  # is streamed and followed live, so a mute made on another device applies.
  defp load_mutes(%{assigns: %{current_user: %{pubky: z32}}} = socket) do
    Mutes.subscribe(z32)
    %{own: own, app: app} = Mutes.of(z32)
    assign(socket, muted: MapSet.union(own, app), app_muted: app, mutes_known: true)
  end

  defp load_mutes(socket), do: socket

  defp assign_room(socket, %{status: status, room: room, members: members} = snapshot) do
    user = socket.assigns.current_user

    bans = Map.get(snapshot, :bans, %{})

    socket
    |> assign(status: status, room: room, page_title: (room && room.name) || "Room")
    |> assign_members(members)
    |> assign(
      is_member: user != nil and user.pubky in members,
      is_creator: user != nil and user.pubky == socket.assigns.creator,
      bans: bans,
      banned?: user != nil and Map.has_key?(bans, user.pubky)
    )
    |> assign(
      unreachable: Map.get(snapshot, :unreachable, []),
      polled: Map.get(snapshot, :polled, []),
      live_unavailable: Map.get(snapshot, :live_unavailable, []),
      viewers: Map.get(snapshot, :viewers, 0)
    )
  end

  defp assign_members(socket, members) do
    profiles = Map.new(members, &{&1, Profiles.get(&1)})
    assign(socket, members: members, profiles: Map.merge(socket.assigns.profiles, profiles))
  end

  # Signed-in viewers are tracked in the room's presence; anonymous ones only
  # subscribe. `online` maps z32 → number of open tabs.
  defp track_presence(%{assigns: %{ref: ref, current_user: user}} = socket) do
    Presence.subscribe(Presence.room_topic(ref))
    if user, do: Presence.track_room(ref, user)
    assign_online(socket, ref)
  end

  defp assign_online(socket, ref) do
    online =
      ref
      |> Presence.room_topic()
      |> Presence.online()
      |> Map.new(fn {z32, metas} -> {z32, length(metas)} end)

    Enum.reduce(Map.keys(online), assign(socket, online: online), &ensure_profile(&2, &1))
  end

  # Nothing known yet, not even from the Directory: one loading state for the
  # whole page rather than placeholders in every component.
  defp loading_shell?(assigns),
    do: is_nil(assigns.room) and assigns.status in [:loading, :bootstrapping]

  # ── events from the browser ────────────────────────────────────────────────

  # Typing after a rejected send clears the error; otherwise a change is a no-op
  # (the typing indicator has its own throttled event from the hook).
  @impl true
  def handle_event("compose", _params, %{assigns: %{composer: %{errors: []}}} = socket),
    do: {:noreply, socket}

  def handle_event("compose", %{"message" => %{"content" => content}}, socket),
    do: {:noreply, assign(socket, composer: composer_form(content))}

  def handle_event("send", %{"message" => %{"content" => content}}, socket) do
    %{current_user: user, sid: sid, ref: ref} = socket.assigns

    cond do
      is_nil(user) ->
        {:noreply, put_flash(socket, :error, "Sign in to chat.")}

      not socket.assigns.is_member ->
        {:noreply, put_flash(socket, :error, "Join the room to chat.")}

      socket.assigns.banned? ->
        {:noreply, put_flash(socket, :error, "You were removed from this room by its owner.")}

      true ->
        case prepare(socket.assigns.composer_mode, sid, user.pubky, ref, content) do
          {:ok, msg} ->
            {:noreply,
             socket
             |> stop_typing()
             |> stream_insert(:messages, msg)
             |> note_shown([msg])
             |> assign(
               composer: composer_form(),
               composer_mode: :new,
               sent: Map.put(socket.assigns.sent, msg.key, msg)
             )
             |> push_event("composer:clear", %{})
             |> start_async({:publish, msg.key}, fn -> Rooms.publish_message(sid, msg) end)}

          {:error, reason} ->
            {:noreply, assign(socket, composer: composer_form(content, Rooms.explain(reason)))}
        end
    end
  end

  # Message actions: reply quotes the message, edit puts its text back into
  # the composer, delete removes the file from the author's homeserver (shown
  # optimistically; the DEL event confirms, a failure restores the row).
  def handle_event("reply", %{"id" => id}, socket) do
    case can_post?(socket) and lookup_message(socket, id) do
      %Message{} = msg ->
        {:noreply,
         socket
         |> assign(composer_mode: {:reply, msg})
         |> push_event("composer:focus", %{})}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("edit", %{"id" => id}, %{assigns: %{current_user: %{pubky: me}}} = socket) do
    case can_post?(socket) and lookup_message(socket, id) do
      %Message{author: ^me} = msg ->
        {:noreply,
         socket
         |> assign(composer_mode: {:edit, msg}, composer: composer_form(msg.content))
         |> push_event("composer:set", %{value: msg.content})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_compose", _params, socket) do
    {:noreply,
     socket
     |> assign(composer_mode: :new, composer: composer_form())
     |> push_event("composer:clear", %{})}
  end

  def handle_event(
        "delete",
        %{"id" => id},
        %{assigns: %{current_user: %{pubky: me}, sid: sid}} = socket
      ) do
    case can_write?(socket) and lookup_message(socket, id) do
      %Message{author: ^me} = msg ->
        {:noreply,
         socket
         |> stream_delete(:messages, msg)
         |> forget_shown(msg.key)
         |> start_async({:delete, msg.key}, fn -> Rooms.delete_message(sid, msg) end)}

      _ ->
        {:noreply, socket}
    end
  end

  # Toggles the viewer's reaction; the homeserver event updates the row.
  def handle_event(
        "react",
        %{"id" => id, "key" => key},
        %{assigns: %{current_user: %{pubky: me}, sid: sid, is_member: true, banned?: false}} =
          socket
      ) do
    case can_post?(socket) and lookup_message(socket, id) do
      %Message{reactions: reactions} = msg ->
        mine? = reactions |> Map.get(key, MapSet.new()) |> MapSet.member?(me)

        {:noreply,
         start_async(socket, {:react, msg.key, key}, fn ->
           if mine?, do: Rooms.unreact(sid, msg, key), else: Rooms.react(sid, msg, key)
         end)}

      nil ->
        {:noreply, socket}
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
         |> note_shown([msg])
         |> start_async({:publish, msg.key}, fn -> Rooms.retry_message(sid, msg) end)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("discard", %{"id" => id}, %{assigns: %{failed: failed}} = socket) do
    case Map.fetch(failed, id) do
      {:ok, msg} ->
        {:noreply,
         socket
         |> assign(failed: Map.delete(failed, id))
         |> stream_delete(:messages, msg)
         |> forget_shown(msg.key)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("retry_history", _params, socket) do
    RoomServer.retry_history(socket.assigns.ref)
    {:noreply, socket}
  end

  # The reader scrolled to the top (or pressed the button): extend the window.
  def handle_event("load_older", _params, socket), do: {:noreply, load_older_page(socket)}

  # A quote was clicked: scroll to the original, loading earlier pages first
  # when it sits outside the window.
  def handle_event("jump", %{"id" => id}, socket) do
    case parse_dom_id(id) do
      {:ok, key} -> {:noreply, jump_to(socket, key)}
      :error -> {:noreply, socket}
    end
  end

  # The composer reports keystrokes; at most one broadcast every 2 s per viewer.
  def handle_event("typing", _params, %{assigns: %{current_user: %{pubky: z32}}} = socket) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_typing_at

    if can_post?(socket) and (is_nil(last) or now - last >= @typing_throttle) do
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

  # Below the `xl` breakpoint the members list lives in a sheet.
  def handle_event("open_members", _params, socket),
    do: {:noreply, assign(socket, members_open: true)}

  def handle_event("close_members", _params, socket),
    do: {:noreply, assign(socket, members_open: false)}

  # Moderation: the creator removes (bans) and restores members; anyone
  # signed in mutes an author for themselves (a marker on their homeserver).
  def handle_event("start_ban", %{"z32" => z32}, %{assigns: %{is_creator: true}} = socket) do
    {:noreply, assign(socket, banning: z32, ban_form: to_form(%{"reason" => ""}, as: :ban))}
  end

  def handle_event("cancel_ban", _params, socket), do: {:noreply, assign(socket, banning: nil)}

  def handle_event(
        "ban",
        %{"ban" => %{"reason" => reason}},
        %{assigns: %{is_creator: true, banning: z32, sid: sid, ref: ref, creator: creator}} =
          socket
      )
      when is_binary(z32) do
    case Ban.validate_reason(reason) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(joining: true)
         |> start_async(:ban, fn -> Rooms.ban(sid, creator, ref, z32, reason) end)}

      {:error, error} ->
        {:noreply,
         assign(socket,
           ban_form: to_form(%{"reason" => reason}, as: :ban, errors: [reason: {error, []}])
         )}
    end
  end

  def handle_event(
        "unban",
        %{"z32" => z32},
        %{assigns: %{is_creator: true, sid: sid, ref: ref, creator: creator}} = socket
      ) do
    {:noreply,
     socket
     |> assign(joining: true)
     |> start_async(:unban, fn -> Rooms.unban(sid, creator, ref, z32) end)}
  end

  # Mutes apply at once and are written in the background; a failed write
  # puts the previous state back.
  def handle_event(
        "mute",
        %{"z32" => z32},
        %{assigns: %{current_user: %{pubky: user}, sid: sid}} = socket
      )
      when z32 != user do
    {:noreply,
     socket
     |> set_muted(MapSet.put(socket.assigns.muted, z32))
     |> start_async({:mute, z32}, fn -> Mutes.mute(sid, user, z32) end)}
  end

  def handle_event(
        "unmute",
        %{"z32" => z32},
        %{assigns: %{current_user: %{pubky: user}, sid: sid, app_muted: app_muted}} = socket
      ) do
    if MapSet.member?(app_muted, z32) do
      {:noreply, put_flash(socket, :info, "You muted them in Pubky App; unmute them there.")}
    else
      {:noreply,
       socket
       |> set_muted(MapSet.delete(socket.assigns.muted, z32))
       |> start_async({:unmute, z32}, fn -> Mutes.unmute(sid, user, z32) end)}
    end
  end

  # Tags: any signed-in user toggles their own tag on the room (a chip they
  # already used removes it) or adds a new label.
  def handle_event(
        "toggle_tag",
        %{"label" => label},
        %{assigns: %{current_user: %{pubky: me}, sid: sid, ref: ref}} = socket
      ) do
    if can_write?(socket) do
      mine? = Directory.tagged_by?(ref, label, me)

      {:noreply,
       start_async(socket, {:tag, label}, fn ->
         if mine?,
           do: Rooms.untag_room(sid, me, ref, label),
           else: Rooms.tag_room(sid, me, ref, label)
       end)}
    else
      {:noreply, socket}
    end
  end

  # From the tag input (UI.TagInput) in the header: `%{"label" => label}`.
  def handle_event(
        "add_tag",
        %{"label" => label},
        %{assigns: %{current_user: %{pubky: me}, sid: sid, ref: ref}} = socket
      ) do
    socket = assign(socket, tag_suggestions: [])

    case {can_write?(socket), Tag.normalize(label)} do
      {true, {:ok, normalized}} ->
        {:noreply,
         start_async(socket, {:tag, normalized}, fn ->
           Rooms.tag_room(sid, me, ref, normalized)
         end)}

      {true, {:error, error}} ->
        {:noreply, put_flash(socket, :error, error)}

      {false, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("tag_query", %{"q" => q}, socket) do
    if can_write?(socket) do
      known = Directory.popular_tags() |> Enum.map(fn {label, _rooms} -> label end)
      taken = Enum.map(socket.assigns.tags, & &1.label)
      {:noreply, assign(socket, tag_suggestions: Tag.suggest(known, q, taken))}
    else
      {:noreply, socket}
    end
  end

  # Room settings (creator only): rename, topic, visibility, close.
  def handle_event(
        "validate_settings",
        %{"room" => params},
        %{assigns: %{is_creator: true, status: :ready}} = socket
      ) do
    {:noreply, assign(socket, settings_form: to_form(params, as: :room))}
  end

  def handle_event(
        "save_settings",
        %{"room" => params},
        %{
          assigns: %{
            is_creator: true,
            status: :ready,
            room: %Room{} = room,
            sid: sid,
            creator: creator
          }
        } =
          socket
      ) do
    case Room.validate(params) do
      {:ok, _fields} ->
        {:noreply,
         socket
         |> assign(saving: true, settings_form: to_form(params, as: :room))
         |> start_async(:save_settings, fn -> Rooms.update_room(sid, creator, room, params) end)}

      {:error, errors} ->
        {:noreply, assign(socket, settings_form: to_form(params, as: :room, errors: errors))}
    end
  end

  def handle_event(
        "close_room",
        _params,
        %{
          assigns: %{
            is_creator: true,
            status: :ready,
            room: %Room{} = room,
            sid: sid,
            creator: creator
          }
        } =
          socket
      ) do
    {:noreply,
     socket
     |> assign(saving: true)
     |> start_async(:close_room, fn -> Rooms.close_room(sid, creator, room) end)}
  end

  # signed-out, non-member or non-creator viewers cannot use these actions
  def handle_event(event, _params, socket)
      when event in ~w(edit delete react start_ban ban unban mute unmute validate_settings save_settings close_room toggle_tag add_tag) do
    {:noreply, socket}
  end

  # Which write the composer performs in its current mode.
  defp prepare(:new, sid, author, ref, content),
    do: Rooms.prepare_message(sid, author, ref, content)

  defp prepare({:reply, %Message{uri: uri}}, sid, author, ref, content),
    do: Rooms.prepare_message(sid, author, ref, content, reply_to: uri)

  defp prepare({:edit, %Message{author: author} = msg}, sid, author, _ref, content),
    do: Rooms.prepare_edit(sid, msg, content)

  defp prepare({:edit, _msg}, _sid, _author, _ref, _content),
    do: {:error, "You can only edit your own messages."}

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

  def handle_async({:delete, _key}, {:ok, :ok}, socket), do: {:noreply, socket}

  def handle_async({:react, _msg_key, _key}, {:ok, :ok}, socket), do: {:noreply, socket}

  def handle_async({:react, _msg_key, _key}, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, "Reaction not stored: " <> Rooms.explain(reason))}

  def handle_async({:react, _msg_key, _key}, {:exit, reason}, socket),
    do: {:noreply, put_flash(socket, :error, Rooms.explain({:unexpected, reason}))}

  def handle_async({:delete, key}, {:ok, {:error, reason}}, socket),
    do: {:noreply, restore_message(socket, key, reason)}

  def handle_async({:delete, key}, {:exit, reason}, socket),
    do: {:noreply, restore_message(socket, key, {:unexpected, reason})}

  def handle_async(:older, {:ok, {:ok, msgs, more?}}, socket) do
    socket = socket |> assign(loading_older: false, has_more: more?) |> prepend_older(msgs)

    case socket.assigns.jump_target do
      nil -> {:noreply, push_event(socket, "older:loaded", %{count: length(msgs)})}
      key -> {:noreply, continue_jump(socket, key, msgs, more?)}
    end
  end

  def handle_async(:older, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(loading_older: false, jump_target: nil)
     |> push_event("older:loaded", %{count: 0})
     |> put_flash(:error, "Earlier messages could not be loaded right now.")}
  end

  def handle_async({:tag, _label}, {:ok, :ok}, socket), do: {:noreply, load_tags(socket)}

  def handle_async({:tag, _label}, {:ok, {:ok, _saved}}, socket),
    do: {:noreply, load_tags(socket)}

  def handle_async({:tag, _label}, {:ok, {:error, reason}}, socket),
    do: {:noreply, put_flash(socket, :error, "Tag not saved: " <> Rooms.explain(reason))}

  def handle_async({:tag, _label}, {:exit, reason}, socket),
    do: {:noreply, put_flash(socket, :error, Rooms.explain({:unexpected, reason}))}

  def handle_async(:save_settings, {:ok, {:ok, %Room{} = room}}, socket) do
    {:noreply,
     socket
     |> assign(saving: false, room: room, page_title: room.name)
     |> put_flash(:success, "Room updated.")
     |> push_patch(to: room_path(socket))}
  end

  def handle_async(:save_settings, {:ok, {:error, errors}}, socket) when is_list(errors) do
    form = to_form(socket.assigns.settings_form.params, as: :room, errors: errors)
    {:noreply, assign(socket, saving: false, settings_form: form)}
  end

  def handle_async(:save_settings, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket |> assign(saving: false) |> put_flash(:error, "Not saved: " <> Rooms.explain(reason))}
  end

  def handle_async(:close_room, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(saving: false)
     |> put_flash(:info, "Room closed. Members' messages stay on their own homeservers.")
     |> push_navigate(to: ~p"/")}
  end

  def handle_async(:close_room, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket |> assign(saving: false) |> put_flash(:error, "Not closed: " <> Rooms.explain(reason))}
  end

  def handle_async(:ban, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(joining: false, banning: nil)
     |> put_flash(:info, "Member removed. Their messages are hidden while the ban is in place.")}
  end

  def handle_async(:ban, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(joining: false)
     |> put_flash(:error, "Not removed: " <> Rooms.explain(reason))}
  end

  def handle_async(:unban, {:ok, :ok}, socket) do
    {:noreply, socket |> assign(joining: false) |> put_flash(:info, "Member restored.")}
  end

  def handle_async(:unban, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(joining: false)
     |> put_flash(:error, "Not restored: " <> Rooms.explain(reason))}
  end

  def handle_async({:mute, _z32}, {:ok, :ok}, socket), do: {:noreply, socket}
  def handle_async({:unmute, _z32}, {:ok, :ok}, socket), do: {:noreply, socket}

  def handle_async({:mute, z32}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> set_muted(MapSet.delete(socket.assigns.muted, z32))
     |> put_flash(:error, "Not muted: " <> Rooms.explain(reason))}
  end

  def handle_async({:unmute, z32}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> set_muted(MapSet.put(socket.assigns.muted, z32))
     |> put_flash(:error, "Not unmuted: " <> Rooms.explain(reason))}
  end

  def handle_async(:join, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> assign(joining: false, is_member: true)
     |> refresh_rows()
     |> put_flash(:success, "You joined the room.")}
  end

  def handle_async(:join, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> assign(joining: false) |> put_flash(:error, Rooms.explain(reason))}
  end

  # the room's {:member_left} event carries the toast, so it shows once
  def handle_async(:leave, {:ok, :ok}, socket) do
    {:noreply, socket |> assign(joining: false, is_member: false) |> refresh_rows()}
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

  def handle_info({:room_stats, ref, %{viewers: viewers}}, %{assigns: %{ref: ref}} = socket) do
    {:noreply, assign(socket, viewers: viewers)}
  end

  # The viewer's mute list changed (this tab, another tab or another device).
  def handle_info({:mutes_updated, z32}, %{assigns: %{current_user: %{pubky: z32}}} = socket) do
    %{own: own, app: app} = Mutes.of(z32)
    muted = MapSet.union(own, app)
    socket = assign(socket, app_muted: app)

    if MapSet.equal?(muted, socket.assigns.muted),
      do: {:noreply, socket},
      else: {:noreply, set_muted(socket, muted)}
  end

  def handle_info({:directory, {:tags_updated, ref}}, %{assigns: %{ref: ref}} = socket),
    do: {:noreply, load_tags(socket)}

  def handle_info({:directory, _event}, socket), do: {:noreply, socket}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{room_monitor: ref}} = socket
      ) do
    {:noreply, socket |> assign(room_pid: nil, room_monitor: nil, status: :loading) |> attach()}
  end

  # Stream items are not re-rendered when assigns change, so the author's
  # visible messages are re-inserted (same DOM ids) from the room's table.
  def handle_info({:profile_updated, z32, profile}, socket) do
    if Map.has_key?(socket.assigns.profiles, z32) do
      socket = assign(socket, profiles: Map.put(socket.assigns.profiles, z32, profile))

      socket =
        case socket.assigns.table do
          nil -> socket
          table -> reinsert(socket, Enum.filter(authored_by(table, z32), &in_window?(socket, &1)))
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
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
    if MapSet.member?(socket.assigns.muted, z32) or Map.has_key?(socket.assigns.bans, z32) do
      {:noreply, socket}
    else
      until = System.monotonic_time(:millisecond) + @typing_ttl

      {:noreply,
       socket
       |> assign(typing: Map.put(socket.assigns.typing, z32, until))
       |> ensure_profile(z32)
       |> schedule_typing_prune()}
    end
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
    socket =
      socket
      |> assign(
        failed: Map.delete(socket.assigns.failed, dom_id(msg)),
        sent: Map.delete(socket.assigns.sent, msg.key),
        typing: Map.delete(socket.assigns.typing, msg.author)
      )
      |> ensure_profile(msg.author)

    socket =
      if MapSet.member?(socket.assigns.muted, msg.author),
        do: socket,
        else: arrive(socket, msg)

    # whatever changed (an edit, or a message coming back through a backfill
    # after its author rejoined), the rows quoting it re-resolve their quote
    refresh_replies(socket, msg.key)
  end

  # The creator gets their own confirmation, the removed member the notice
  # under the messages; everyone else is told why rows just vanished.
  defp apply_room_event(socket, {:member_banned, z32, reason}) do
    me? = match?(%{pubky: ^z32}, socket.assigns.current_user)

    socket
    |> assign(
      bans: Map.put(socket.assigns.bans, z32, reason),
      typing: Map.delete(socket.assigns.typing, z32)
    )
    |> then(fn s ->
      cond do
        me? ->
          s
          |> assign(banned?: true, composer_mode: :new)
          |> refresh_rows()
          |> put_flash(:error, "You have been removed from this room.")

        s.assigns.is_creator ->
          s

        true ->
          put_flash(
            s,
            :info,
            "#{member_name(s, z32)} was removed by the owner; their messages are hidden."
          )
      end
    end)
  end

  defp apply_room_event(socket, {:member_unbanned, z32}) do
    me? = match?(%{pubky: ^z32}, socket.assigns.current_user)

    socket
    |> assign(bans: Map.delete(socket.assigns.bans, z32))
    |> then(fn s ->
      cond do
        me? ->
          s
          |> assign(banned?: false)
          |> refresh_rows()
          |> put_flash(:info, "You were restored by the owner; your messages are back.")

        s.assigns.is_creator ->
          s

        true ->
          put_flash(
            s,
            :info,
            "#{member_name(s, z32)} was restored by the owner; their messages are back."
          )
      end
    end)
  end

  defp apply_room_event(socket, {:message_deleted, key}) do
    socket
    |> stream_delete_by_dom_id(:messages, dom_id(key))
    |> forget_shown(key)
    |> refresh_replies(key)
  end

  defp apply_room_event(socket, {:message_failed, key, reason}),
    do: fail_message(socket, key, reason)

  defp apply_room_event(socket, {:member_joined, z32}) do
    socket
    |> assign_members(Enum.uniq([z32 | socket.assigns.members]))
    |> maybe_set_member(z32, true)
  end

  # Their rows leave with them ({:message_deleted} each); the toast says why.
  defp apply_room_event(socket, {:member_left, z32}) do
    me? = match?(%{pubky: ^z32}, socket.assigns.current_user)

    notice =
      if me?,
        do: "You left the room. Your messages went with you; join again to bring them back.",
        else:
          "#{profile_of(socket.assigns.profiles, z32).name} left the room; their messages went with them."

    socket
    |> assign_members(List.delete(socket.assigns.members, z32))
    |> maybe_set_member(z32, false)
    |> put_flash(:info, notice)
  end

  defp apply_room_event(socket, {:room_updated, room}),
    do: assign(socket, room: room, page_title: room.name)

  defp apply_room_event(socket, :room_closed) do
    socket
    |> assign(status: :closed, composer_mode: :new, banning: nil)
    |> refresh_rows()
    |> put_flash(:info, "The owner closed this room.")
  end

  defp apply_room_event(socket, {:unavailable, status}), do: assign(socket, status: status)
  defp apply_room_event(socket, {:unreachable, members}), do: assign(socket, unreachable: members)
  defp apply_room_event(socket, {:polled, members}), do: assign(socket, polled: members)

  defp apply_room_event(socket, {:live_unavailable, members}),
    do: assign(socket, live_unavailable: members)

  defp apply_room_event(socket, _other), do: socket

  defp member_name(socket, z32), do: profile_of(socket.assigns.profiles, z32).name

  defp maybe_set_member(%{assigns: %{current_user: %{pubky: z32}}} = socket, z32, value),
    do: socket |> assign(is_member: value) |> refresh_rows()

  defp maybe_set_member(socket, _z32, _value), do: socket

  # Re-renders the window without (or again with) the author's messages.
  defp set_muted(socket, muted) do
    socket =
      assign(socket, muted: muted, typing: Map.drop(socket.assigns.typing, MapSet.to_list(muted)))

    case socket.assigns.table do
      nil -> socket
      table -> show_window(socket, unmuted(socket, RoomServer.history(table)))
    end
  end

  defp ensure_profile(socket, z32) do
    if Map.has_key?(socket.assigns.profiles, z32),
      do: socket,
      else: assign(socket, profiles: Map.put(socket.assigns.profiles, z32, Profiles.get(z32)))
  end

  # Stream items cannot be read back, so messages sent from this LiveView are
  # kept in `sent` until confirmed; a failure re-renders them from there. A
  # failed *edit* puts the stored version back instead.
  defp fail_message(socket, key, reason) do
    case Map.get(socket.assigns.sent, key) do
      nil ->
        socket

      %Message{edited_at: edited_at} = msg ->
        socket = assign(socket, sent: Map.delete(socket.assigns.sent, key))

        case {edited_at, stored_message(socket, key)} do
          {nil, _} ->
            msg = %{msg | state: :failed, fail_reason: reason}

            socket
            |> assign(failed: Map.put(socket.assigns.failed, dom_id(key), msg))
            |> stream_insert(:messages, msg)

          {_edited, %Message{} = original} ->
            socket
            |> stream_insert(:messages, original)
            |> put_flash(:error, "Edit not stored: " <> Rooms.explain(reason))

          {_edited, nil} ->
            msg = %{msg | state: :failed, fail_reason: reason}

            socket
            |> assign(failed: Map.put(socket.assigns.failed, dom_id(key), msg))
            |> stream_insert(:messages, msg)
        end
    end
  end

  # A delete that did not land: show the message again.
  defp restore_message(socket, key, reason) do
    socket = put_flash(socket, :error, "Not deleted: " <> Rooms.explain(reason))

    case stored_message(socket, key) do
      %Message{} = msg -> stream_insert(socket, :messages, msg)
      nil -> socket
    end
  end

  # Works on the socket (handlers) or on assigns (render).
  defp stored_message(%{assigns: assigns}, key), do: stored_message(assigns, key)
  defp stored_message(%{table: nil}, _key), do: nil

  defp stored_message(%{table: table}, key) do
    case :ets.info(table) != :undefined and :ets.lookup(table, key) do
      [{^key, msg}] -> msg
      _ -> nil
    end
  end

  # DOM id → stored message (`msg-<author z32>-<msg_id>`).
  defp lookup_message(socket, "msg-" <> rest) when byte_size(rest) > 53 do
    <<author::binary-size(52), "-", msg_id::binary>> = rest
    stored_message(socket, {msg_id, author})
  end

  defp lookup_message(_socket, _id), do: nil

  # What a reply quotes: the original's author and text, if we hold it.
  defp quote_of(_socket, %Message{reply_to: nil}), do: nil

  # `%{id, name, content}` when the room holds the original; `{:missing, id}`
  # when it may still be further up in the history; `:unavailable` when it
  # cannot be (the whole history is loaded, or it would sit inside the loaded
  # window: deleted, or never readable).
  defp quote_of(assigns, %Message{reply_to: uri}) do
    case Paths.parse_message_uri(uri) do
      {:ok, {author, _ref, msg_id}} -> resolve_quote(assigns, author, msg_id)
      :error -> :unavailable
    end
  end

  # a muted author's words never reach the viewer, not even quoted
  defp resolve_quote(%{mutes_known: true, muted: muted}, author, _msg_id)
       when is_map_key(muted.map, author),
       do: :muted

  defp resolve_quote(assigns, author, msg_id) do
    case stored_message(assigns, {msg_id, author}) do
      %Message{} = original ->
        %{
          id: dom_id(original),
          name: profile_of(assigns.profiles, author).name,
          content: Format.truncate(original.content, 140)
        }

      nil ->
        if within_window?(assigns, msg_id),
          do: :unavailable,
          else: {:missing, dom_id({msg_id, author})}
    end
  end

  # Message ids are time-ordered, so an id at or after the oldest loaded one
  # belongs inside the loaded window; with no more history there is no "earlier".
  defp within_window?(%{has_more: false}, _msg_id), do: true
  defp within_window?(%{oldest_key: {oldest, _author}}, msg_id), do: msg_id >= oldest
  defp within_window?(_assigns, _msg_id), do: false

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
      <.container class="flex h-[calc(100dvh-5rem)] flex-col gap-3 pb-24 lg:h-[calc(100dvh-7rem)] lg:pb-6">
        <div
          :if={loading_shell?(assigns)}
          id="room-loading"
          class="flex flex-1 flex-col items-center justify-center gap-3 text-sm text-muted-foreground"
          role="status"
        >
          <.spinner class="size-6" />
          <span>Loading the room…</span>
        </div>
        <.room_header
          :if={not loading_shell?(assigns)}
          room={@room}
          bans={@bans}
          status={@status}
          members={@members}
          online_count={map_size(@online)}
          anonymous_count={Rooms.anonymous_count(@viewers, @online)}
          is_member={@is_member}
          banned={@banned?}
          current_user={@current_user}
          joining={@joining}
          creator={@creator}
          room_id={@room_id}
        />
        <.tag_row
          :if={@room && (@tags != [] or can_tag?(assigns))}
          tags={@tags}
          viewer={@current_user && @current_user.pubky}
          creator={@creator}
          writer={can_tag?(assigns)}
          remover={can_write?(assigns)}
          suggestions={@tag_suggestions}
        />

        <div :if={not loading_shell?(assigns)} class="flex min-h-0 flex-1 gap-6">
          <div class="flex min-w-0 flex-1 flex-col overflow-hidden rounded-xl bg-card">
            <div
              :if={@unreachable != []}
              class="flex flex-wrap items-center justify-between gap-2 border-b border-border/60 px-4 py-1.5 text-xs text-muted-foreground"
              role="status"
            >
              <span class="flex items-center gap-2">
                <.icon name="lucide-cloud-off" class="size-3.5 shrink-0 text-destructive" />
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
              class="flex items-start gap-2 border-b border-border/60 px-4 py-2 text-xs text-muted-foreground"
              role="status"
            >
              <.icon name="lucide-unplug" class="mt-px size-3.5 shrink-0" />
              <span>
                Live updates from {members_phrase(length(@live_unavailable))} are unavailable right now;
                new messages appear once their homeserver is back.
              </span>
            </div>
            <div
              :if={@polled != []}
              id="polled-members"
              class="flex items-start gap-2 border-b border-border/60 px-4 py-2 text-xs text-muted-foreground"
              role="status"
            >
              <.icon name="lucide-timer" class="mt-px size-3.5 shrink-0" />
              <span>
                This room is over the live-subscription budget: {members_phrase(length(@polled))} are checked for new messages about once a minute instead of live.
              </span>
            </div>
            <div
              id="messages"
              phx-update="stream"
              phx-hook="ScrollToBottom"
              data-has-more={to_string(@has_more)}
              class="flex flex-1 flex-col overflow-x-hidden overflow-y-auto px-2 py-3 sm:px-4"
              aria-live="polite"
            >
              <div
                id="messages-top"
                class={["order-first flex shrink-0 justify-center py-1", !@has_more && "hidden"]}
              >
                <.button
                  variant="ghost"
                  size="sm"
                  phx-click="load_older"
                  disabled={@loading_older}
                  class="text-muted-foreground"
                >
                  <.spinner :if={@loading_older} class="size-4" />
                  <.icon :if={!@loading_older} name="lucide-clock-arrow-up" class="size-4" />
                  {if @loading_older, do: "Loading earlier messages…", else: "Load earlier messages"}
                </.button>
              </div>
              <div
                id="messages-empty"
                class="hidden flex-1 flex-col items-center justify-center gap-2 py-16 text-center text-sm text-muted-foreground [#messages:not(:has(>_[id^=msg-]))_&]:flex"
              >
                <.empty_state
                  :if={@status == :ready}
                  icon="lucide-message-square-dashed"
                  title="No messages yet"
                  class="bg-transparent"
                />
                <.empty_state
                  :if={@status == :closed}
                  icon="lucide-door-closed"
                  title="No messages"
                  class="bg-transparent"
                />
                <.spinner :if={@status in [:loading, :bootstrapping]} class="size-6" />
                <span :if={@status in [:loading, :bootstrapping]}>Loading messages…</span>
                <span :if={@status == :not_found}>This room does not exist on its owner's homeserver.</span>
                <span :if={match?({:error, _}, @status)}>The owner's homeserver could not be reached. Try again later.</span>
              </div>
              <.message_row
                :for={{id, msg} <- @streams.messages}
                id={id}
                msg={msg}
                profile={Map.get(@profiles, msg.author) || Profiles.get(msg.author)}
                own={@current_user != nil && @current_user.pubky == msg.author}
                can_edit={
                  @current_user != nil && @current_user.pubky == msg.author && can_post?(assigns)
                }
                can_delete={
                  @current_user != nil && @current_user.pubky == msg.author && can_write?(assigns)
                }
                can_reply={can_post?(assigns)}
                viewer={@current_user && @current_user.pubky}
                muted={@muted}
                quote={quote_of(assigns, msg)}
              />
            </div>

            <.typing_line typing={@typing} profiles={@profiles} />

            <div class="shrink-0 border-t border-border/60 p-3 sm:p-4">
              <%= cond do %>
                <% @status in [:closed, :not_found] -> %>
                  <div
                    id="closed-notice"
                    class="flex items-start gap-2 text-sm text-muted-foreground"
                    role="status"
                  >
                    <.icon name="lucide-door-closed" class="mt-0.5 size-4 shrink-0 text-destructive" />
                    <span :if={@status == :closed}>
                      This room was closed by its owner and is read-only now. Messages stay on
                      their authors' homeservers.
                    </span>
                    <span :if={@status == :not_found}>
                      This room does not exist on its owner's homeserver.
                    </span>
                  </div>
                <% is_nil(@current_user) -> %>
                  <div class="flex flex-wrap items-center justify-between gap-3 text-sm text-muted-foreground">
                    <span>Sign in to chat.</span>
                    <.button navigate={~p"/login?return_to=#{room_path(assigns)}"}>
                      <.icon name="lucide-key-round" class="size-4" /> Sign in
                    </.button>
                  </div>
                <% @banned? -> %>
                  <div
                    id="banned-notice"
                    class="flex items-start gap-2 text-sm text-muted-foreground"
                    role="status"
                  >
                    <.icon name="lucide-user-x" class="mt-0.5 size-4 shrink-0 text-destructive" />
                    <span class="flex min-w-0 flex-1 flex-wrap items-center gap-x-1.5 gap-y-1">
                      <span>You were removed from this room by its owner.</span>
                      <%!-- not <.badge>: badges never wrap, a reason may be 140 chars --%>
                      <span
                        :if={@bans[@current_user.pubky]}
                        id="banned-reason"
                        class="inline-block max-w-full rounded-md border border-destructive/40 bg-destructive/16 px-2 py-0.5 text-xs font-medium break-words text-destructive"
                      >
                        <span class="sr-only">Reason:</span>
                        {@bans[@current_user.pubky]}
                      </span>
                      <span>Your messages stay on your homeserver; they are hidden here.</span>
                    </span>
                  </div>
                <% not @is_member -> %>
                  <div class="flex flex-wrap items-center justify-between gap-3 text-sm text-muted-foreground">
                    <span>Join the room to chat.</span>
                    <.button variant="brand" phx-click="join" disabled={@joining or @status != :ready}>
                      <.spinner :if={@joining} class="size-4" />
                      <.icon :if={!@joining} name="lucide-log-in" class="size-4" /> Join room
                    </.button>
                  </div>
                <% true -> %>
                  <.form
                    for={@composer}
                    id="composer"
                    phx-submit="send"
                    phx-change="compose"
                    phx-throttle="500"
                    class="flex flex-col gap-2"
                  >
                    <.composer_context mode={@composer_mode} profiles={@profiles} />
                    <div
                      id="composer-box"
                      phx-click={JS.focus(to: "#composer-input")}
                      class="flex cursor-text items-end gap-3 rounded-md border border-dashed border-input px-4 py-3 focus-within:border-ring"
                    >
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
                        placeholder="Say hello…"
                        rows="1"
                        maxlength={Message.content_max()}
                        wrapper_class="flex-1"
                        class="py-1.5 md:py-2"
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
                        <.icon name="lucide-corner-down-left" class="size-4" />
                      </.button>
                    </div>
                    <p class="flex flex-wrap items-center gap-1.5 px-1 text-xs text-muted-foreground">
                      <span>Enter to send, Shift+Enter for a new line.</span>
                      <button
                        type="button"
                        id="composer-storage-tip"
                        class="tooltip inline-flex rounded-full text-muted-foreground outline-none hover:text-foreground focus-visible:text-foreground"
                        data-tip={"Stored at pubky://#{Profiles.short_key(@current_user.pubky)}/pub/pubky-rooms/…"}
                        aria-label={"Stored at pubky://#{Profiles.short_key(@current_user.pubky)}/pub/pubky-rooms/…"}
                      >
                        <.icon name="lucide-info" class="size-3.5" />
                      </button>
                    </p>
                  </.form>
              <% end %>
            </div>
          </div>

          <aside class="hidden w-64 shrink-0 flex-col gap-4 xl:flex">
            <.members_panel
              id_prefix=""
              members={@members}
              bans={@bans}
              online={@online}
              viewers={@viewers}
              profiles={@profiles}
              creator={@creator}
              current_user={@current_user}
              is_creator={@is_creator}
              unreachable={@unreachable}
              live_unavailable={@live_unavailable}
              polled={@polled}
              muted={@muted}
              mutes_known={@mutes_known}
              app_muted={@app_muted}
              busy={@joining}
            />
          </aside>
        </div>
      </.container>

      <.dialog
        :if={@members_open}
        id="members-sheet"
        show
        on_cancel={JS.push("close_members")}
        class="xl:hidden"
        labelled_by="sheet-members-title"
        described_by="sheet-members-description"
      >
        <.members_panel
          id_prefix="sheet-"
          card={false}
          members={@members}
          bans={@bans}
          online={@online}
          viewers={@viewers}
          profiles={@profiles}
          creator={@creator}
          current_user={@current_user}
          is_creator={@is_creator}
          unreachable={@unreachable}
          live_unavailable={@live_unavailable}
          polled={@polled}
          muted={@muted}
          mutes_known={@mutes_known}
          app_muted={@app_muted}
          busy={@joining}
        />
      </.dialog>

      <.dialog
        :if={@live_action == :settings and @settings_form}
        id="room-settings"
        show
        on_cancel={JS.patch(room_path(assigns))}
        size="wide"
      >
        <:title>Room settings</:title>
        <.form
          for={@settings_form}
          id="room-settings-form"
          phx-change="validate_settings"
          phx-submit="save_settings"
          class="flex flex-col gap-5"
        >
          <.input field={@settings_form[:name]} label="Name" maxlength={Room.name_max()} />
          <.input
            field={@settings_form[:topic]}
            type="textarea"
            label="Topic"
            rows="2"
            maxlength={Room.topic_max()}
          />
          <.choice_cards
            field={@settings_form[:visibility]}
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
        </.form>
        <div class="flex flex-col gap-2 rounded-md border border-destructive/40 p-4 text-sm">
          <p class="font-semibold">Close this room</p>
          <p class="text-muted-foreground">
            Deletes the room definition from your homeserver. The room stops resolving for everyone;
            members' messages remain on their own homeservers.
          </p>
          <div>
            <.button
              variant="destructive-soft"
              size="sm"
              class="w-full sm:w-auto"
              phx-click="close_room"
              disabled={@saving}
              data-confirm="Close this room for everyone? This deletes the room definition from your homeserver."
            >
              <.icon name="lucide-door-closed" class="size-4" /> Close room
            </.button>
          </div>
        </div>
        <:footer>
          <.button variant="ghost" patch={room_path(assigns)}>Cancel</.button>
          <.button variant="brand" type="submit" form="room-settings-form" disabled={@saving}>
            <.spinner :if={@saving} class="size-4" />
            <.icon :if={!@saving} name="lucide-save" class="size-4" /> Save
          </.button>
        </:footer>
      </.dialog>

      <.dialog :if={@banning} id="ban-dialog" show on_cancel={JS.push("cancel_ban")}>
        <:title>Remove {profile_of(@profiles, @banning).name} from this room?</:title>
        <:description>
          A ban marker is written to your homeserver; their messages and reactions are hidden in this
          room for everyone and they cannot post until you restore them. Their files stay on their
          own homeserver.
        </:description>
        <.form for={@ban_form} id="ban-form" phx-submit="ban" class="flex flex-col gap-4">
          <.input
            field={@ban_form[:reason]}
            label="Reason (optional, shown to them)"
            maxlength={Ban.reason_max()}
            placeholder="Spam, harassment…"
            autofocus
          />
        </.form>
        <:footer>
          <.button variant="ghost" phx-click="cancel_ban">Cancel</.button>
          <.button variant="destructive" type="submit" form="ban-form" disabled={@joining}>
            <.spinner :if={@joining} class="size-4" />
            <.icon :if={!@joining} name="lucide-user-x" class="size-4" /> Remove member
          </.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end

  defp profile_of(profiles, z32), do: Map.get(profiles, z32) || Profiles.fallback(z32)

  defp active_members(members, bans), do: Enum.reject(members, &Map.has_key?(bans, &1))

  attr :id_prefix, :string,
    required: true,
    doc: "keeps row ids unique when the panel is shown twice"

  attr :card, :boolean,
    default: true,
    doc: "in a card (the xl sidebar) or plain (inside the members sheet)"

  attr :members, :list, required: true
  attr :bans, :map, required: true
  attr :online, :map, required: true
  attr :viewers, :integer, required: true
  attr :profiles, :map, required: true
  attr :creator, :string, required: true
  attr :current_user, :any, required: true
  attr :is_creator, :boolean, required: true
  attr :unreachable, :list, required: true
  attr :live_unavailable, :list, required: true
  attr :polled, :list, required: true
  attr :muted, MapSet, required: true
  attr :app_muted, MapSet, required: true

  attr :mutes_known, :boolean,
    default: true,
    doc: "false only in the first-render fallback: no mute markers or actions yet"

  attr :busy, :boolean, default: false

  # The members list with per-member status markers and actions, the
  # removed list ("Removed by you" for the owner, who can restore; "Removed by
  # the owner" for everyone else) and the signed-in visitors. One component
  # for both places it appears: as cards in the sidebar from `xl`, and plain
  # inside `#members-sheet` below (same heading, same rows, same actions).
  defp members_panel(assigns) do
    ~H"""
    <.panel_section card={@card}>
      <:header>
        <.section_title
          id={"#{@id_prefix}members-title"}
          class="flex items-center gap-2 text-xl"
        >
          <.icon name="lucide-users" class="size-5 text-muted-foreground" />
          Members · {length(active_members(@members, @bans))}
        </.section_title>
        <p id={"#{@id_prefix}members-description"} class="text-xs text-muted-foreground">
          <.live_dot
            class="mr-1 size-2 align-middle"
            active={members_online(active_members(@members, @bans), @online) > 0}
          />
          {members_online(active_members(@members, @bans), @online)} online
        </p>
      </:header>
      <div
        :for={z32 <- sort_members(active_members(@members, @bans), @online, @profiles)}
        class="group/member flex items-center gap-3"
        id={"#{@id_prefix}member-#{z32}"}
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
        <.badge :if={z32 == @creator} variant="brand-soft">owner</.badge>
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
          <.icon name="lucide-unplug" class="size-4" />
        </span>
        <span
          :if={z32 in @polled}
          class="tooltip text-muted-foreground"
          data-tip="Checked once a minute (over the live budget)"
          aria-label="Checked once a minute (over the live budget)"
        >
          <.icon name="lucide-timer" class="size-4" />
        </span>
        <.member_actions
          :if={@current_user && @current_user.pubky != z32}
          z32={z32}
          muted={MapSet.member?(@muted, z32)}
          mutes_known={@mutes_known}
          app_muted={MapSet.member?(@app_muted, z32)}
          can_ban={@is_creator and z32 != @creator}
          busy={@busy}
        />
      </div>
      <%!-- ban markers are public files on the owner's homeserver, so the list
           is shown to everyone; only the owner can restore --%>
      <div :if={@bans != %{}} class="flex flex-col gap-3 border-t border-border/60 pt-4">
        <p class="text-xs font-semibold text-muted-foreground">
          {if @is_creator, do: "Removed by you", else: "Removed by the owner"}
        </p>
        <div
          :for={{z32, reason} <- Enum.sort(@bans)}
          class="flex items-center gap-3"
          id={"#{@id_prefix}banned-#{z32}"}
        >
          <.avatar
            src={profile_of(@profiles, z32).avatar_url}
            name={profile_of(@profiles, z32).name}
            pubky={z32}
            size="md"
            class="opacity-60"
          />
          <span class="flex min-w-0 flex-1 items-center gap-1.5">
            <span class="truncate text-sm font-semibold text-muted-foreground">
              {profile_of(@profiles, z32).name}
            </span>
            <%!-- the reason (up to 140 chars) lives in a popover on hover/focus,
                 wrapping, anchored to the icon and kept inside the card --%>
            <span :if={reason} class="group/reason relative inline-flex shrink-0">
              <button
                type="button"
                class="flex size-5 items-center justify-center rounded-full text-muted-foreground hover:text-foreground"
                aria-label="Reason"
                aria-describedby={"#{@id_prefix}banned-#{z32}-reason"}
              >
                <.icon name="lucide-user-x" class="size-3.5" />
              </button>
              <span
                id={"#{@id_prefix}banned-#{z32}-reason"}
                role="tooltip"
                class="pointer-events-none absolute right-0 bottom-full z-20 mb-1.5 hidden w-56 rounded-md border border-border bg-secondary px-2.5 py-1.5 text-xs break-words text-secondary-foreground shadow-md group-hover/reason:block group-focus-within/reason:block"
              >
                {reason}
              </span>
            </span>
          </span>
          <.button
            :if={@is_creator}
            variant="ghost"
            size="sm"
            phx-click="unban"
            phx-value-z32={z32}
            disabled={@busy}
          >
            Restore
          </.button>
        </div>
      </div>
    </.panel_section>
    <.panel_section
      :if={visitors(@online, @members) != [] or Rooms.anonymous_count(@viewers, @online) > 0}
      id={"#{@id_prefix}also-here"}
      card={@card}
    >
      <:header>
        <.section_title class="text-xl">Also here</.section_title>
        <p class="text-xs text-muted-foreground">In the room without being members</p>
      </:header>
      <div
        :if={Rooms.anonymous_count(@viewers, @online) > 0}
        class="flex items-center gap-3 text-sm text-muted-foreground"
        title="Viewers who are not signed in"
      >
        <span class="flex size-8 shrink-0 items-center justify-center rounded-full bg-white/5">
          <.icon name="lucide-eye" class="size-4" />
        </span>
        <span class="min-w-0 flex-1 truncate">
          {anonymous_label(Rooms.anonymous_count(@viewers, @online))}
        </span>
      </div>
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
    </.panel_section>
    """
  end

  attr :id, :string, default: nil
  attr :card, :boolean, required: true
  slot :header, required: true
  slot :inner_block, required: true

  # A section of the members panel: a card in the sidebar, a plain block in
  # the sheet (whose own panel is the surface; the header clears the close x).
  defp panel_section(%{card: true} = assigns) do
    ~H"""
    <.card id={@id} class="gap-3 py-5">
      <.card_header>{render_slot(@header)}</.card_header>
      <.card_content class="flex flex-col gap-3">{render_slot(@inner_block)}</.card_content>
    </.card>
    """
  end

  defp panel_section(assigns) do
    ~H"""
    <section id={@id} class="flex flex-col gap-4">
      <div class="flex flex-col gap-1.5 pr-8">{render_slot(@header)}</div>
      <div class="flex flex-col gap-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  defp anonymous_label(1), do: "1 anonymous viewer"
  defp anonymous_label(n), do: "#{n} anonymous viewers"

  attr :z32, :string, required: true
  attr :muted, :boolean, required: true
  attr :app_muted, :boolean, default: false, doc: "muted through Pubky App (read-only here)"
  attr :mutes_known, :boolean, default: true
  attr :can_ban, :boolean, required: true
  attr :busy, :boolean, default: false

  @hover_only "sm:opacity-0 sm:group-hover/member:opacity-100 sm:group-has-[:focus-visible]/member:opacity-100"

  # Per-member actions, revealed on hover/focus of the row. The mute control is
  # both the state and the action: a muted member's button stays visible in its
  # "on" look and unmutes on click; a mute made in Pubky App is shown the same
  # way but is read-only here.
  defp member_actions(assigns) do
    assigns = assign(assigns, hover_only: @hover_only)

    ~H"""
    <span class="flex shrink-0 items-center gap-0.5">
      <button
        :if={@mutes_known and !@app_muted}
        type="button"
        phx-click={if @muted, do: "unmute", else: "mute"}
        phx-value-z32={@z32}
        class={[
          "flex size-7 cursor-pointer items-center justify-center rounded-full",
          if(@muted,
            do: "bg-white/10 text-foreground hover:bg-white/15",
            else: [@hover_only, "text-muted-foreground hover:bg-white/10 hover:text-foreground"]
          )
        ]}
        aria-pressed={to_string(@muted)}
        aria-label={if @muted, do: "Unmute", else: "Mute for me"}
        title={if @muted, do: "Muted for you", else: "Mute for me"}
      >
        <.icon name="lucide-volume-x" class="size-4" />
      </button>
      <span
        :if={@mutes_known and @app_muted}
        class="tooltip flex size-7 items-center justify-center rounded-full bg-white/10 text-muted-foreground"
        data-tip="Muted in Pubky App"
        aria-label="Muted in Pubky App"
      >
        <.icon name="lucide-volume-x" class="size-4" />
      </span>
      <button
        :if={@can_ban}
        type="button"
        phx-click="start_ban"
        phx-value-z32={@z32}
        disabled={@busy}
        class={[
          @hover_only,
          "flex size-7 cursor-pointer items-center justify-center rounded-full text-muted-foreground hover:bg-destructive/20 hover:text-destructive"
        ]}
        aria-label="Remove from room"
        title="Remove from room"
      >
        <.icon name="lucide-user-x" class="size-4" />
      </button>
    </span>
    """
  end

  defp authored_by(table, z32) do
    if :ets.info(table) == :undefined,
      do: [],
      else: table |> RoomServer.history() |> Enum.filter(&(&1.author == z32))
  end

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

  defp members_online(members, online), do: Enum.count(members, &Map.has_key?(online, &1))

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
  attr :bans, :map, required: true
  attr :online_count, :integer, required: true
  attr :anonymous_count, :integer, default: 0
  attr :is_member, :boolean, required: true
  attr :banned, :boolean, default: false
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
        <span
          :if={@room && @room.visibility == "unlisted" && @status != :closed}
          id="unlisted-label"
          class="inline-flex shrink-0 items-center gap-1 px-2 py-0.5 text-xs font-medium"
        >
          <.icon name="lucide-link" class="size-3" /> Unlisted
        </span>
        <.badge :if={@status == :closed} id="closed-badge" variant="destructive-soft">
          <.icon name="lucide-door-closed" class="size-3" /> Closed
        </.badge>
      </div>
      <div class="flex shrink-0 items-center gap-2">
        <button
          type="button"
          id="members-button"
          phx-click="open_members"
          class="flex cursor-pointer items-center gap-1 rounded-full px-2 py-1 text-xs text-muted-foreground hover:bg-white/5 hover:text-foreground xl:hidden"
          title="Members"
          aria-label="Show members"
        >
          <.icon name="lucide-users" class="size-3.5" /> {length(active_members(@members, @bans))}
        </button>
        <span
          class="flex items-center gap-1.5 text-xs text-muted-foreground xl:hidden"
          title="Signed-in people in the room right now"
        >
          <.live_dot active={@online_count > 0} />
          <span id="online-count">{@online_count} online</span>
        </span>
        <span
          :if={@anonymous_count > 0}
          id="anonymous-count"
          class="hidden items-center gap-1 text-xs text-muted-foreground sm:flex xl:hidden"
          title="Viewers who are not signed in"
        >
          <.icon name="lucide-eye" class="size-3.5" /> {anonymous_label(@anonymous_count)}
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
          :if={@is_member && !@banned && @current_user && @current_user.pubky != @creator}
          variant="ghost"
          size="sm"
          phx-click="leave"
          data-confirm="Leave the room? Your messages leave with you (they stay on your homeserver); joining again brings them back."
          disabled={@joining}
        >
          Leave
        </.button>
        <.button
          :if={
            @current_user && @current_user.pubky == @creator && @room &&
              !Room.closed?(@room) && @status in [:loading, :ready]
          }
          variant="secondary"
          size="icon"
          patch={~p"/r/#{@creator}/#{@room_id}/settings"}
          aria-label="Room settings"
          data-tip="Settings"
          class="tooltip"
        >
          <.icon name="lucide-settings" class="size-4" />
        </.button>
      </div>
    </header>
    """
  end

  attr :tags, :list, required: true, doc: "`Directory.tags_of/1` result"
  attr :viewer, :string, default: nil, doc: "marks the viewer's own tags"
  attr :creator, :string, default: nil, doc: "the creator keeps the automatic label"
  attr :writer, :boolean, default: false, doc: "whether the viewer may add tags"
  attr :remover, :boolean, default: false, doc: "whether the viewer may remove their own tags"
  attr :suggestions, :list, default: [], doc: "labels offered by the tag input"

  # Universal tags on the room: click to add or remove your own; the tag input
  # (same one as the create dialog) adds a new label. Anonymous viewers just
  # see them; on an unlisted room only removing your own tag is possible; the
  # creator's automatic "room" label is fixed (the server refuses too).
  defp tag_row(assigns) do
    ~H"""
    <div id="room-tags" class="flex flex-wrap items-center gap-1.5">
      <.tag
        :for={t <- @tags}
        label={t.label}
        count={t.count}
        size="sm"
        selected={@viewer != nil and @viewer in t.taggers}
        disabled={
          fixed_tag?(t, @viewer, @creator) or
            not (@writer or (@remover and @viewer != nil and @viewer in t.taggers))
        }
        phx-click="toggle_tag"
        phx-value-label={t.label}
        title={
          cond do
            fixed_tag?(t, @viewer, @creator) -> "Added automatically"
            @viewer in t.taggers -> "Remove your tag"
            true -> "Tag this room too"
          end
        }
      />
      <.tag_input
        :if={@writer}
        id="room-tag-input"
        size="sm"
        suggestions={@suggestions}
        placeholder="add tag"
      />
    </div>
    """
  end

  # a mute is the viewer's own: it takes the muted people's reactions off every
  # row for them (a ban does it for everyone, in the room server)
  defp visible_reactions(reactions, muted) do
    reactions
    |> Enum.map(fn {key, reactors} -> {key, MapSet.difference(reactors, muted)} end)
    |> Enum.reject(fn {_key, reactors} -> MapSet.size(reactors) == 0 end)
    |> Map.new()
  end

  defp fixed_tag?(%{label: label, taggers: taggers}, viewer, creator),
    do: viewer != nil and viewer == creator and label == Tag.auto_label() and viewer in taggers

  attr :mode, :any, required: true, doc: ":new | {:reply, msg} | {:edit, msg}"
  attr :profiles, :map, required: true

  defp composer_context(%{mode: :new} = assigns), do: ~H""

  defp composer_context(assigns) do
    {verb, msg} =
      case assigns.mode do
        {:reply, msg} -> {"Replying to", msg}
        {:edit, msg} -> {"Editing your message", msg}
      end

    assigns =
      assign(assigns,
        verb: verb,
        name: profile_of(assigns.profiles, msg.author).name,
        excerpt: Format.truncate(msg.content, 100),
        editing?: match?({:edit, _}, assigns.mode)
      )

    ~H"""
    <div
      id="composer-context"
      class="flex items-center gap-2 rounded-md bg-white/[0.04] px-3 py-1.5 text-xs text-muted-foreground"
    >
      <.icon name={if @editing?, do: "lucide-pencil", else: "lucide-reply"} class="size-3.5 shrink-0" />
      <span class="min-w-0 flex-1 truncate">
        <span class="font-semibold text-secondary-foreground">{@verb}</span>
        <span :if={!@editing?} class="font-semibold text-secondary-foreground">{@name}:</span>
        {@excerpt}
      </span>
      <button
        type="button"
        phx-click="cancel_compose"
        class="flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-full hover:bg-white/10 hover:text-foreground"
        aria-label="Cancel"
      >
        <.icon name="lucide-x" class="size-3.5" />
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :msg, Message, required: true
  attr :profile, :map, required: true
  attr :own, :boolean, default: false, doc: "shows the delivery state"

  attr :can_edit, :boolean,
    default: false,
    doc: "own message, still a member (editing needs the composer)"

  attr :can_delete, :boolean,
    default: false,
    doc:
      "own message in an open room, not banned; membership is not needed to delete your own file"

  attr :can_reply, :boolean, default: false, doc: "also gates reacting"
  attr :viewer, :string, default: nil, doc: "the viewer's z32, to mark their own reactions"
  attr :muted, :any, default: MapSet.new(), doc: "reactions by muted authors are left out"

  attr :quote, :any,
    default: nil,
    doc: "nil | :unavailable | :muted | {:missing, id} | %{id, name, content}"

  defp message_row(assigns) do
    assigns =
      assign(assigns,
        # copy is for every viewer, so a stored message always has a pill
        actions?: assigns.msg.state == :confirmed,
        reactions: visible_reactions(assigns.msg.reactions, assigns.muted)
      )

    ~H"""
    <article
      id={@id}
      class="group relative flex gap-2.5 rounded-md px-2 py-1.5 transition-colors hover:bg-white/[0.03]"
    >
      <%!-- the toggle and the pill share a positioned box (click-away needs a
           real box; `display: contents` is skipped) so a tap anywhere else closes
           the pill on phones; opening one also closes the others; no-op from sm up --%>
      <div
        :if={@actions?}
        id={"#{@id}-menu"}
        class="absolute top-1 right-1 size-7"
        phx-click-away={JS.add_class("max-sm:hidden", to: "##{@id}-actions")}
      >
        <button
          type="button"
          phx-click={
            JS.add_class("max-sm:hidden", to: "#messages [data-actions]:not(##{@id}-actions)")
            |> JS.toggle_class("max-sm:hidden", to: "##{@id}-actions")
          }
          class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted-foreground/70 hover:bg-white/10 hover:text-foreground sm:hidden"
          aria-label="More actions"
          aria-controls={"#{@id}-actions"}
        >
          <.icon name="lucide-ellipsis" class="size-4" />
        </button>
        <div
          id={"#{@id}-actions"}
          data-actions
          class="absolute -top-3.5 right-1 z-10 flex items-center gap-0.5 rounded-full border border-border bg-card p-0.5 shadow-xs max-sm:hidden sm:opacity-0 sm:group-hover:opacity-100 sm:group-has-[:focus-visible]:opacity-100"
        >
          <button
            :if={@can_reply}
            type="button"
            phx-click={
              JS.toggle(to: "##{@id}-palette", display: "flex")
              |> JS.add_class("max-sm:hidden", to: "##{@id}-actions")
            }
            class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted-foreground hover:bg-white/10 hover:text-foreground"
            aria-label="React"
            title="React"
            aria-controls={"#{@id}-palette"}
          >
            <.icon name="lucide-face-slightly-smiling-plus" class="size-4" />
          </button>
          <button
            :if={@can_reply}
            type="button"
            phx-click={
              JS.push("reply", value: %{id: @id})
              |> JS.add_class("max-sm:hidden", to: "##{@id}-actions")
            }
            class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted-foreground hover:bg-white/10 hover:text-foreground"
            aria-label="Reply"
            title="Reply"
          >
            <.icon name="lucide-reply" class="size-4" />
          </button>
          <button
            type="button"
            id={"#{@id}-copy"}
            phx-hook="Clipboard"
            data-copy={@msg.content}
            phx-click={JS.add_class("max-sm:hidden", to: "##{@id}-actions")}
            class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted-foreground hover:bg-white/10 hover:text-foreground"
            aria-label="Copy text"
            title="Copy text"
          >
            <.icon name="lucide-copy" class="size-4" />
          </button>
          <button
            :if={@can_edit}
            type="button"
            phx-click={
              JS.push("edit", value: %{id: @id})
              |> JS.add_class("max-sm:hidden", to: "##{@id}-actions")
            }
            class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted-foreground hover:bg-white/10 hover:text-foreground"
            aria-label="Edit"
            title="Edit"
          >
            <.icon name="lucide-pencil" class="size-4" />
          </button>
          <button
            :if={@can_delete}
            type="button"
            phx-click={
              JS.push("delete", value: %{id: @id})
              |> JS.add_class("max-sm:hidden", to: "##{@id}-actions")
            }
            data-confirm="Delete this message from your homeserver?"
            class="flex size-7 cursor-pointer items-center justify-center rounded-full text-muted-foreground hover:bg-destructive/20 hover:text-destructive"
            aria-label="Delete"
            title="Delete"
          >
            <.icon name="lucide-trash" class="size-4" />
          </button>
        </div>
        <%!-- the palette pops out under the pill, where the click happened --%>
        <div
          :if={@can_reply}
          id={"#{@id}-palette"}
          class="absolute top-[22px] right-0 z-20 hidden items-center gap-0.5 rounded-full border border-border bg-card p-1 shadow-md"
          phx-click-away={JS.hide(to: "##{@id}-palette")}
          role="group"
          aria-label="Choose a reaction"
        >
          <button
            :for={{key, emoji} <- Reaction.palette()}
            type="button"
            phx-click={
              JS.push("react", value: %{id: @id, key: key}) |> JS.hide(to: "##{@id}-palette")
            }
            class="flex size-7 cursor-pointer items-center justify-center rounded-full text-base hover:bg-white/10"
            aria-label={"React with #{key}"}
          >
            {emoji}
          </button>
        </div>
      </div>
      <.avatar
        src={@profile.avatar_url}
        name={@profile.name}
        pubky={@msg.author}
        size="md"
        class="mt-0.5"
      />
      <div class="flex min-w-0 flex-1 flex-col">
        <div class="flex min-w-0 items-baseline gap-x-2 pr-8 sm:pr-0">
          <span class="truncate text-sm font-semibold leading-5">{@profile.name}</span>
          <time
            datetime={Format.iso(@msg.created_at)}
            class="shrink-0 text-[11px] text-muted-foreground"
            title={Format.iso(@msg.created_at)}
          >
            {Format.clock(@msg.created_at)}
          </time>
          <span :if={@msg.edited_at} class="shrink-0 text-[11px] text-muted-foreground">(edited)</span>
          <span
            :if={@own and @msg.state == :pending}
            class="tooltip tooltip-bottom inline-flex shrink-0 self-center text-muted-foreground"
            data-tip="Sending to your homeserver…"
          >
            <.icon name="lucide-clock" class="size-3" />
          </span>
          <span
            :if={@own and @msg.state == :confirmed}
            class="tooltip tooltip-bottom inline-flex shrink-0 self-center text-brand/80"
            data-tip="Stored on your homeserver"
          >
            <.icon name="lucide-check" class="size-3" />
          </span>
          <span
            :if={@own and @msg.state == :failed}
            class="inline-flex shrink-0 self-center text-destructive"
          >
            <.icon name="lucide-circle-x" class="size-3" />
          </span>
        </div>
        <button
          :if={is_map(@quote)}
          type="button"
          phx-click="jump"
          phx-value-id={@quote.id}
          class="mt-0.5 mb-1 flex min-w-0 max-w-full cursor-pointer items-baseline gap-1.5 border-l-2 border-brand/60 pl-2 text-left text-xs text-muted-foreground hover:text-secondary-foreground"
          title="Show the original message"
        >
          <span class="shrink-0 font-semibold">{@quote.name}</span>
          <span class="min-w-0 truncate">{@quote.content}</span>
        </button>
        <button
          :if={match?({:missing, _}, @quote)}
          type="button"
          phx-click="jump"
          phx-value-id={elem(@quote, 1)}
          class="mt-0.5 mb-1 flex cursor-pointer items-center gap-1 border-l-2 border-border pl-2 text-xs italic text-muted-foreground hover:text-secondary-foreground"
          title="Load earlier messages up to the original"
        >
          <.icon name="lucide-clock-arrow-up" class="size-3" />
          Replying to an earlier message — show it
        </button>
        <span
          :if={@quote == :unavailable}
          class="mt-0.5 mb-1 border-l-2 border-border pl-2 text-xs italic text-muted-foreground"
        >
          Replying to a message that is no longer available
        </span>
        <span
          :if={@quote == :muted}
          class="mt-0.5 mb-1 border-l-2 border-border pl-2 text-xs italic text-muted-foreground"
        >
          Replying to someone you muted
        </span>
        <%!-- pre-wrap renders template whitespace, so the text hugs its tags --%>
        <p
          phx-no-format
          class={[
            "whitespace-pre-wrap break-words text-sm leading-5 text-secondary-foreground",
            @msg.state == :pending && "opacity-60"
          ]}
        ><Linkify.linkify text={@msg.content} /></p>
        <div :if={@reactions != %{}} class="mt-1 flex flex-wrap gap-1">
          <button
            :for={{key, reactors} <- Enum.sort_by(@reactions, &elem(&1, 0))}
            type="button"
            phx-click={@can_reply && JS.push("react", value: %{id: @id, key: key})}
            disabled={!@can_reply}
            aria-pressed={to_string(@viewer != nil and MapSet.member?(reactors, @viewer))}
            class={[
              "flex h-6 items-center gap-1 rounded-full border px-1.5 text-[11px] transition-colors",
              @can_reply && "cursor-pointer hover:bg-white/10",
              if(@viewer != nil and MapSet.member?(reactors, @viewer),
                do: "border-brand/60 bg-brand/15 text-foreground",
                else: "border-border bg-white/[0.03] text-secondary-foreground"
              )
            ]}
            title={"#{key} · #{MapSet.size(reactors)}"}
          >
            <span aria-hidden="true">{Reaction.emoji(key)}</span>
            <span class="sr-only">{key}</span>
            <span class="font-semibold">{MapSet.size(reactors)}</span>
          </button>
        </div>
        <div
          :if={@msg.state == :failed}
          class="mt-1 flex flex-wrap items-center gap-2 text-xs text-destructive"
        >
          <.icon name="lucide-circle-alert" class="size-3.5" />
          <span>Not stored: {Rooms.explain(@msg.fail_reason)}</span>
          <button
            type="button"
            phx-click="retry"
            phx-value-id={@id}
            class="inline-flex h-6 cursor-pointer items-center rounded-full border border-destructive/40 bg-destructive/16 px-2.5 font-medium text-destructive transition-colors outline-none hover:bg-destructive/25 focus-visible:ring-[3px] focus-visible:ring-ring/50"
          >
            Retry
          </button>
          <button
            type="button"
            phx-click="discard"
            phx-value-id={@id}
            class="inline-flex h-6 cursor-pointer items-center rounded-full px-1.5 font-medium text-destructive/80 underline-offset-2 transition-colors outline-none hover:text-destructive hover:underline focus-visible:ring-[3px] focus-visible:ring-ring/50"
          >
            Discard
          </button>
        </div>
      </div>
    </article>
    """
  end
end

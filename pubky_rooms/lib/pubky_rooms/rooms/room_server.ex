defmodule PubkyRooms.Rooms.RoomServer do
  @moduledoc """
  One process per open room: the live, in-memory view of a room assembled
  from its members' homeservers.

  Lifecycle:

    1. **Bootstrap** — read the room definition from the creator's homeserver,
       acquire event subscriptions for every known member (this captures
       their cursors first, so nothing is missed), list every member's message
       folder in parallel, fetch only the newest `bootstrap_messages` overall
       (message ids are time-ordered), and become `:ready`. Cost is
       *members + messages shown*, not members × messages.
    2. **Live** — apply homeserver events: message `PUT`s become fetches (or
       instant confirmations when the content hash matches a pending write
       from this node), `DEL`s remove, reaction markers toggle a reaction on
       the message (no fetch: the path says it all), join markers add and
       remove members, room definition changes update or close the room.
       A **closed** room stays alive as a read-only archive: its history is
       still assembled from the members' folders (also on a later bootstrap,
       from the directory's `closed_at` row when the definition is gone),
       members' own edits and deletes still apply, but this app disables
       every write. The creator writing the definition again reopens it.
    3. **Idle** — with no viewers attached for `room_idle_timeout_ms` the room
       releases its subscriptions and stops (sooner when more than
       `max_idle_rooms` rooms are alive); the next visit bootstraps again.
    4. **Unreachable history** — members whose folder could not be listed are
       reported as `{:unreachable, [z32]}` (and in the snapshot) and retried
       every minute while viewers are attached, or on `retry_history/1`.
    5. **Live budget** — at most `max_members_subscribed` members (creator
       first) get event subscriptions; members beyond that are *polled*: their
       folders are re-listed every `member_poll_ms` while viewers are
       attached (`{:polled, [z32]}`). A poll is **exact**: it pages down a
       member's folder until it meets a message the room already holds (or
       the folder ends), fetches every new message it found (no cap), and
       treats a message older than one poll interval that vanished from the
       listed range (the member's newest page, at least) as deleted. Edits
       by polled members, and deletions further down, wait for the next
       bootstrap. Members whose stream is down are reported as
       `{:live_unavailable, [z32]}` from `Subscriptions` status broadcasts.
       Nobody is ever dropped from a room.

    6. **Paging** — listing entries that were not fetched at bootstrap stay
       in memory per member (with the listing cursor for more); `older/3`
       extends the in-memory window downwards from them, newest first, so a
       viewer scrolling up always sees a complete, ordered history. Paged
       messages are inserted silently (no broadcast): only the viewer who
       asked prepends them.
    7. **Bans** — markers under `bans/<room_id>/` on the *creator's*
       homeserver (listed at bootstrap, applied live) hide a member's messages
       and reactions and are reported as `{:member_banned, z32, reason}`;
       deleting the marker restores them (`{:member_unbanned, z32}` and a
       backfill). Markers anywhere else are ignored.
    8. **Viewers** — every attached viewer (signed in or not) is monitored;
       the total is announced as `{:room_stats, ref, %{viewers: n}}` on
       `stats_topic/1`, debounced to at most one broadcast per
       `viewers_debounce_ms`. Only a count, never who (ADR 0006).

  Messages live in a public ETS `ordered_set` keyed by `{msg_id, author}`,
  so viewers read history directly. Changes are broadcast on the room topic as
  `{:room_event, ref, event}`; see `PubkyRoomsWeb.RoomLive` for the consumer.
  `:ready` means "the snapshot is available" — its `status` is `:ready` for an
  open room and `:closed` for an archive.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Pubky.Crypto.Blake3
  alias PubkyRooms.{Events, Ids, Pubky, Telemetry}
  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.Rooms.{Ban, Directory, Message, Paths, Room}

  @sweep_every 5_000
  @stop_after_error 30_000
  @retry_history_every 60_000
  @default_budget 5_000
  @default_poll_ms 60_000
  @default_viewers_debounce 2_000
  @history_limit 200
  @max_paging_rounds 5
  @max_poll_pages 40

  @type ref :: Paths.room_ref()
  @type status :: :bootstrapping | :ready | :not_found | :closed | {:error, term()}

  # ── API ────────────────────────────────────────────────────────────────────

  @doc "The PubSub topic of a room."
  @spec topic(ref()) :: String.t()
  def topic({creator, id}), do: "room:#{creator}/#{id}"

  @doc "The low-volume topic carrying `{:room_stats, ref, %{viewers: n}}` (lobby cards subscribe here)."
  @spec stats_topic(ref()) :: String.t()
  def stats_topic({creator, id}), do: "room:#{creator}/#{id}:stats"

  @doc "How many viewers (signed in or anonymous) have the room open on this node; 0 when it is not running."
  @spec viewer_count(ref()) :: non_neg_integer()
  def viewer_count(ref) do
    case whereis(ref) do
      nil -> 0
      pid -> GenServer.call(pid, :viewer_count)
    end
  catch
    :exit, _ -> 0
  end

  @doc "Starts the room's server if it is not running."
  @spec ensure(ref()) :: {:ok, pid()} | {:error, term()}
  def ensure(ref) do
    case DynamicSupervisor.start_child(PubkyRooms.Rooms.RoomSupervisor, {__MODULE__, ref}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "The pid of a running room server, if any."
  @spec whereis(ref()) :: pid() | nil
  def whereis(ref) do
    case Registry.lookup(PubkyRooms.Rooms.Registry, ref) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def start_link(ref), do: GenServer.start_link(__MODULE__, ref, name: via(ref))
  defp via(ref), do: {:via, Registry, {PubkyRooms.Rooms.Registry, ref}}

  @doc "Registers the caller as a viewer and returns the current snapshot."
  @spec attach(ref(), pid()) :: {:ok, map()}
  def attach(ref, viewer \\ self()), do: GenServer.call(via(ref), {:attach, viewer})

  @doc "The current snapshot without registering as a viewer."
  def snapshot(ref), do: GenServer.call(via(ref), :snapshot)

  @doc """
  The snapshot of a room server that is already running, or nil: never starts
  one and gives up after a second (a server mid-bootstrap is busy). For the
  disconnected first render of the room page, which must stay cheap.
  """
  @spec peek(ref()) :: map() | nil
  def peek(ref) do
    case whereis(ref) do
      nil -> nil
      pid -> pid |> GenServer.call(:snapshot, 1_000) |> unwrap_snapshot()
    end
  catch
    :exit, _ -> nil
  end

  defp unwrap_snapshot({:ok, snapshot}), do: snapshot
  defp unwrap_snapshot(_), do: nil

  @doc "Reads the newest `limit` messages from the room's ETS table, oldest first."
  @spec history(:ets.tid(), pos_integer()) :: [Message.t()]
  def history(table, limit \\ @history_limit) do
    case :ets.select_reverse(table, [{{:_, :"$1"}, [], [:"$1"]}], limit) do
      {msgs, _cont} -> Enum.reverse(msgs)
      :"$end_of_table" -> []
    end
  end

  @doc "How many messages `history/2` returns at most (the initial window of a viewer)."
  def history_limit, do: @history_limit

  @doc """
  The newest `limit` messages older than the message `before` (a key), oldest
  first, fetching more from members' homeservers when the in-memory window
  runs out. `more?` tells whether anything older may exist.
  """
  @spec older(ref(), Message.key(), pos_integer()) :: {:ok, [Message.t()], boolean()}
  def older(ref, before, limit), do: GenServer.call(via(ref), {:older, before, limit}, 90_000)

  @doc "Records a message this node is about to write; its PUT event confirms it by hash."
  @spec register_pending(ref(), Message.t(), binary()) :: :ok
  def register_pending(ref, %Message{} = msg, hash),
    do: GenServer.call(via(ref), {:register_pending, msg, hash})

  @doc "Retries loading history for members whose homeserver could not be reached."
  @spec retry_history(ref()) :: :ok
  def retry_history(ref), do: GenServer.cast(via(ref), :retry_history)

  @doc "Forgets a pending message whose write failed."
  @spec cancel_pending(ref(), Message.key()) :: :ok
  def cancel_pending(ref, key), do: GenServer.call(via(ref), {:cancel_pending, key})

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init({creator, id} = ref) do
    Process.flag(:trap_exit, true)
    table = :ets.new(:room_messages, [:ordered_set, :public, read_concurrency: true])

    state = %{
      ref: ref,
      creator: creator,
      id: id,
      room: nil,
      status: :bootstrapping,
      table: table,
      members: MapSet.new([creator]),
      subscribed: MapSet.new(),
      polled: MapSet.new(),
      live_unavailable: MapSet.new(),
      pending: %{},
      viewers: %{},
      idle_timer: nil,
      unreachable: MapSet.new(),
      retry_timer: nil,
      poll_timer: nil,
      viewers_timer: nil,
      older: %{},
      paging: false,
      waiters: [],
      reactions: %{},
      bans: %{},
      started_at: System.monotonic_time()
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case Directory.fetch_room(state.ref) do
      {:ok, room} ->
        Directory.put_room(room)
        bootstrap(state, room, :ready)

      {:error, :not_found} ->
        # The definition is gone. A room this node knew is an archive now
        # (the DEL event may not have reached the directory yet); a room it
        # never knew does not exist.
        case Directory.get(state.ref) do
          %Room{} = known ->
            Directory.close_room(state.ref)
            Directory.touch(state.ref)
            room = %{known | closed_at: known.closed_at || System.os_time(:millisecond)}
            bootstrap(state, room, :closed)

          nil ->
            fail(state, :not_found)
        end

      {:error, reason} ->
        fail(state, {:error, reason})
    end
  end

  defp bootstrap(state, room, status) do
    members = MapSet.new(Directory.members_of(state.ref))
    {subscribed, polled} = split_budget(state.creator, members)
    state = %{state | room: room, members: members, subscribed: subscribed, polled: polled}
    Subscriptions.acquire(subscribed, self())
    # PubSub topics are free: polled members' events still arrive when
    # anyone else on this node follows them (e.g. their own session).
    Enum.each(members, &Events.subscribe_user/1)
    Subscriptions.subscribe()
    Directory.subscribe()
    state = %{state | bans: load_bans(state)}
    state = backfill_sync(state, MapSet.difference(members, banned_set(state)))
    state = apply_statuses(state, Subscriptions.statuses(subscribed))
    Process.send_after(self(), :sweep_pending, @sweep_every)
    state = %{state | status: status}

    Telemetry.bootstrap(
      state.started_at,
      %{members: MapSet.size(members), messages: :ets.info(state.table, :size)},
      status
    )

    broadcast(state, :ready)
    {:noreply, state |> maybe_start_idle_timer() |> schedule_poll()}
  end

  defp fail(state, status) do
    Logger.info("room #{inspect(state.ref)} unavailable: #{inspect(status)}")
    state = %{state | status: status}
    broadcast(state, {:unavailable, status})
    Process.send_after(self(), :stop, @stop_after_error)
    {:noreply, state}
  end

  @impl true
  def handle_call({:attach, viewer}, _from, state) do
    state =
      if Map.has_key?(state.viewers, viewer),
        do: state,
        else: state |> put_in([:viewers, viewer], Process.monitor(viewer)) |> viewers_changed()

    {:reply, {:ok, snapshot_of(state)}, state |> cancel_idle_timer() |> schedule_poll()}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, snapshot_of(state)}, state}
  def handle_call(:viewer_count, _from, state), do: {:reply, map_size(state.viewers), state}

  def handle_call({:older, before, limit}, from, state) do
    case older_from_table(state, before, limit) do
      {:ok, msgs, _more?} = reply when length(msgs) >= limit ->
        {:reply, reply, state}

      {:ok, _msgs, false} = reply ->
        {:reply, reply, state}

      _ ->
        waiters = [{from, before, limit, 0} | state.waiters]
        {:noreply, start_paging(%{state | waiters: waiters}, limit)}
    end
  end

  def handle_call({:register_pending, msg, hash}, _from, state) do
    pending =
      Map.put(state.pending, msg.key, %{
        hash: hash,
        msg: msg,
        at: System.monotonic_time(:millisecond)
      })

    {:reply, :ok, %{state | pending: pending}}
  end

  def handle_call({:cancel_pending, key}, _from, state) do
    {:reply, :ok, %{state | pending: Map.delete(state.pending, key)}}
  end

  @impl true
  def handle_cast(:retry_history, state), do: {:noreply, retry_unreachable(state)}

  @impl true
  def handle_info({:pubky_event, %{user: user, path: path, type: type} = ev}, state) do
    state =
      case Paths.parse(path) do
        {:message, c, id, msg_id} when {c, id} == state.ref ->
          if banned?(state, user),
            do: state,
            else: handle_message_event(state, type, user, msg_id, ev.content_hash)

        {:reaction, c, id, author, msg_id, key} when {c, id} == state.ref ->
          if banned?(state, user),
            do: state,
            else: handle_reaction_event(state, type, user, {msg_id, author}, key)

        {:ban, id, banned} when user == state.creator and id == state.id ->
          handle_ban_event(state, type, banned)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:directory, event}, state) do
    ref = state.ref

    state =
      case event do
        {:member_joined, ^ref, z32} ->
          add_member(state, z32)

        {:member_left, ^ref, z32} ->
          remove_member(state, z32)

        {:room_updated, %{creator: c, id: id} = room} when {c, id} == ref ->
          update_room(state, room)

        {:room_closed, %{creator: c, id: id} = room} when {c, id} == ref ->
          close(state, room)

        {:room_removed, ^ref} ->
          close(state, state.room)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:fetched, key, result}, state) do
    {:noreply, apply_fetch(state, key, result)}
  end

  # The reason of a ban applied live arrives a moment later.
  def handle_info({:ban_reason, z32, reason}, state) do
    case state.bans do
      %{^z32 => ban} when ban.reason != reason ->
        state = put_in(state.bans[z32], %{ban | reason: reason})
        broadcast(state, {:member_banned, z32, reason})
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:backfilled, members, history}, state) do
    {:noreply, apply_backfill(state, members, history)}
  end

  # A poll came back: new messages land like a backfill; then every message
  # of a listed member that is older than `since` and missing from the
  # listing has been deleted on their homeserver.
  def handle_info({:poll_result, members, since, history, listed}, state) do
    state = apply_backfill(state, members, history)
    {:noreply, Enum.reduce(listed, state, &apply_poll_listing(&2, &1, since))}
  end

  # A paging round finished: store the messages silently (the viewer who asked
  # prepends them; nobody else is interested), then answer the waiters, some
  # of whom may need another round.
  def handle_info({:extended, {msgs, older, progress?}}, state) do
    Enum.each(msgs, &insert_silently(state, &1))
    state = %{state | older: older, paging: false}
    {waiters, state} = {state.waiters, %{state | waiters: []}}

    state =
      Enum.reduce(waiters, state, fn {from, before, limit, rounds}, acc ->
        {:ok, found, more?} = reply = older_from_table(acc, before, limit)

        if length(found) >= limit or not more? or not progress? or
             rounds + 1 >= @max_paging_rounds do
          GenServer.reply(from, reply)
          acc
        else
          %{acc | waiters: [{from, before, limit, rounds + 1} | acc.waiters]}
        end
      end)

    case state.waiters do
      [] -> {:noreply, state}
      [{_, _, limit, _} | _] -> {:noreply, start_paging(state, limit)}
    end
  end

  def handle_info(:retry_history, state) do
    state = %{state | retry_timer: nil}

    if map_size(state.viewers) > 0,
      do: {:noreply, retry_unreachable(state)},
      else: {:noreply, state}
  end

  # Members over the live budget: re-list their folders while someone watches.
  def handle_info(:poll_members, state) do
    state = %{state | poll_timer: nil}

    if map_size(state.viewers) > 0 and MapSet.size(state.polled) > 0 do
      poll_async(state, MapSet.to_list(state.polled))
      {:noreply, schedule_poll(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:subscription_status, z32, status}, state) do
    if MapSet.member?(state.subscribed, z32),
      do: {:noreply, apply_statuses(state, %{z32 => status})},
      else: {:noreply, state}
  end

  def handle_info(:sweep_pending, state) do
    timeout = Application.get_env(:pubky_rooms, :confirm_timeout_ms, 15_000)
    now = System.monotonic_time(:millisecond)

    for {_key, %{at: at, msg: msg}} <- state.pending, now - at > timeout do
      fetch_async(msg.author, state.ref, msg.msg_id, :verify)
    end

    Process.send_after(self(), :sweep_pending, @sweep_every)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | viewers: Map.delete(state.viewers, pid)}
    {:noreply, state |> viewers_changed() |> maybe_start_idle_timer()}
  end

  # Always announced, even when the total is back where it was: a viewer that
  # attached in between took its count from a snapshot that still included a
  # page being closed (a refresh), and only this broadcast corrects it.
  def handle_info(:announce_viewers, state) do
    Phoenix.PubSub.broadcast(
      PubkyRooms.PubSub,
      stats_topic(state.ref),
      {:room_stats, state.ref, %{viewers: map_size(state.viewers)}}
    )

    {:noreply, %{state | viewers_timer: nil}}
  end

  def handle_info(:idle_stop, state) do
    if map_size(state.viewers) == 0, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(:stop, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Subscriptions.release(state.subscribed, self())
    :ok
  end

  # ── events ─────────────────────────────────────────────────────────────────

  defp handle_message_event(state, :put, author, msg_id, hash) do
    key = {msg_id, author}

    cond do
      not MapSet.member?(state.members, author) ->
        state

      match?(%{hash: ^hash}, state.pending[key]) ->
        {%{msg: msg, at: at}, pending} = Map.pop(state.pending, key)
        Telemetry.confirm(System.monotonic_time(:millisecond) - at, :event)
        upsert(%{state | pending: pending}, %{msg | state: :confirmed})

      true ->
        fetch_async(author, state.ref, msg_id, :event)
        state
    end
  end

  defp handle_message_event(state, :del, author, msg_id, _hash) do
    key = {msg_id, author}
    :ets.delete(state.table, key)
    broadcast(state, {:message_deleted, key})

    %{
      state
      | pending: Map.delete(state.pending, key),
        reactions: Map.delete(state.reactions, key)
    }
  end

  # ── reactions ──────────────────────────────────────────────────────────────

  # `reactions` maps message key → %{reaction key => MapSet of reactors}; the
  # message row in the table carries a copy so viewers render it directly.
  defp handle_reaction_event(state, type, reactor, msg_key, key) do
    if MapSet.member?(state.members, reactor),
      do: set_reaction(state, msg_key, key, reactor, type == :put, broadcast: true),
      else: state
  end

  defp set_reaction(state, msg_key, key, reactor, on?, opts) do
    by_key = Map.get(state.reactions, msg_key, %{})
    reactors = Map.get(by_key, key, MapSet.new())

    reactors =
      if on?, do: MapSet.put(reactors, reactor), else: MapSet.delete(reactors, reactor)

    by_key =
      if MapSet.size(reactors) == 0,
        do: Map.delete(by_key, key),
        else: Map.put(by_key, key, reactors)

    reactions =
      if by_key == %{},
        do: Map.delete(state.reactions, msg_key),
        else: Map.put(state.reactions, msg_key, by_key)

    state = %{state | reactions: reactions}
    refresh_message_reactions(state, msg_key, opts[:broadcast])
  end

  # Pushes the current reactions of a message into its table row.
  defp refresh_message_reactions(state, msg_key, broadcast?) do
    with [{^msg_key, %Message{} = msg}] <- :ets.lookup(state.table, msg_key),
         updated = with_reactions(state, msg),
         true <- updated != msg do
      :ets.insert(state.table, {msg_key, updated})
      if broadcast?, do: broadcast(state, {:message_upserted, updated})
    end

    state
  end

  # A listing of members' reaction folders: `{reactor, msg_key, key}` triples.
  # Each listed member's reactions are replaced wholesale (a poll may reveal
  # removals the events missed).
  defp apply_listed_reactions(state, {listed_members, triples}, opts) do
    listed = MapSet.new(listed_members)
    wanted = MapSet.new(triples)

    current =
      for {msg_key, by_key} <- state.reactions,
          {key, reactors} <- by_key,
          reactor <- reactors,
          MapSet.member?(listed, reactor),
          into: MapSet.new(),
          do: {reactor, msg_key, key}

    state =
      Enum.reduce(MapSet.difference(current, wanted), state, fn {reactor, msg_key, key}, acc ->
        set_reaction(acc, msg_key, key, reactor, false, opts)
      end)

    Enum.reduce(MapSet.difference(wanted, current), state, fn {reactor, msg_key, key}, acc ->
      set_reaction(acc, msg_key, key, reactor, true, opts)
    end)
  end

  defp with_reactions(state, %Message{key: key} = msg),
    do: %{msg | reactions: Map.get(state.reactions, key, %{})}

  defp add_member(state, z32) do
    if MapSet.member?(state.members, z32) do
      state
    else
      Events.subscribe_user(z32)
      state = %{state | members: MapSet.put(state.members, z32)}

      state =
        if MapSet.size(state.subscribed) < budget() do
          Subscriptions.acquire([z32], self())
          %{state | subscribed: MapSet.put(state.subscribed, z32)}
        else
          state |> set_polled(MapSet.put(state.polled, z32)) |> schedule_poll()
        end

      unless banned?(state, z32), do: backfill_async(state, [z32])
      broadcast(state, {:member_joined, z32})
      state
    end
  end

  defp remove_member(state, z32) when z32 == state.creator, do: state

  defp remove_member(state, z32) do
    if MapSet.member?(state.subscribed, z32), do: Subscriptions.release([z32], self())
    Events.unsubscribe_user(z32)
    broadcast(state, {:member_left, z32})

    # the room only ever shows what current members hold: the leaver's rows go
    # with them (their files stay on their homeserver; a rejoin backfills them)
    state
    |> set_polled(MapSet.delete(state.polled, z32))
    |> set_live_unavailable(MapSet.delete(state.live_unavailable, z32))
    |> Map.update!(:members, &MapSet.delete(&1, z32))
    |> Map.update!(:subscribed, &MapSet.delete(&1, z32))
    |> drop_author(z32)
  end

  # ── bans ───────────────────────────────────────────────────────────────────

  defp banned?(state, z32), do: Map.has_key?(state.bans, z32)
  defp banned_set(state), do: state.bans |> Map.keys() |> MapSet.new()

  # Bootstrap: one listing of the creator's ban folder plus one small read per
  # marker for its reason (bans are rare). Unreadable markers still ban.
  defp load_bans(state) do
    dir = Paths.bans_dir(state.id)

    case retrying(fn -> Pubky.list(state.creator, dir, limit: 1_000) end) do
      {:ok, %{entries: entries}} ->
        for %{path: path} <- entries,
            {:ban, _id, z32} <- [Paths.parse(path)],
            into: %{},
            do: {z32, read_ban(state.creator, path)}

      {:error, reason} ->
        if reason != :not_found,
          do: Logger.debug("bans of #{inspect(state.ref)} unavailable: #{inspect(reason)}")

        %{}
    end
  end

  defp read_ban(creator, path) do
    with {:ok, bytes} <- Pubky.get(creator, path),
         {:ok, ban} <- Ban.decode(bytes) do
      ban
    else
      _ -> %{created_at: nil, reason: nil}
    end
  end

  defp handle_ban_event(state, :put, z32) when z32 == state.creator, do: state

  defp handle_ban_event(state, :put, z32) do
    if banned?(state, z32) do
      state
    else
      state = put_in(state.bans[z32], %{created_at: System.os_time(:millisecond), reason: nil})
      broadcast(state, {:member_banned, z32, nil})
      fetch_ban_reason(state, z32)
      drop_author(state, z32)
    end
  end

  defp handle_ban_event(state, :del, z32) do
    if banned?(state, z32) do
      state = %{state | bans: Map.delete(state.bans, z32)}
      broadcast(state, {:member_unbanned, z32})
      if MapSet.member?(state.members, z32), do: backfill_async(state, [z32])
      state
    else
      state
    end
  end

  defp fetch_ban_reason(state, z32) do
    server = self()
    %{creator: creator, id: id} = state

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      %{reason: reason} = read_ban(creator, Paths.ban(id, z32))
      send(server, {:ban_reason, z32, reason})
    end)
  end

  # An author's messages leave the table (each one announced as deleted) and
  # their reactions leave every row; paging forgets their entries too. Shared
  # by bans and by leaving: both mean the room no longer holds that author.
  defp drop_author(state, z32) do
    keys = :ets.select(state.table, [{{{:_, z32}, :_}, [], [{:element, 1, :"$_"}]}])

    Enum.each(keys, fn key ->
      :ets.delete(state.table, key)
      broadcast(state, {:message_deleted, key})
    end)

    state = %{state | older: Map.delete(state.older, z32), pending: Map.drop(state.pending, keys)}
    state = %{state | reactions: Map.drop(state.reactions, keys)}

    theirs =
      for {msg_key, by_key} <- state.reactions,
          {key, reactors} <- by_key,
          MapSet.member?(reactors, z32),
          do: {msg_key, key}

    Enum.reduce(theirs, state, fn {msg_key, key}, acc ->
      set_reaction(acc, msg_key, key, z32, false, broadcast: true)
    end)
  end

  # ── live budget ────────────────────────────────────────────────────────────

  # The creator always gets a live subscription; the rest in key order.
  defp split_budget(creator, members) do
    ordered = [creator | members |> MapSet.delete(creator) |> Enum.sort()]
    {subscribed, polled} = Enum.split(ordered, budget())
    {MapSet.new(subscribed), MapSet.new(polled)}
  end

  defp budget, do: max(config(:max_members_subscribed, @default_budget), 1)

  defp schedule_poll(%{poll_timer: nil, polled: polled} = state) do
    if MapSet.size(polled) > 0 and map_size(state.viewers) > 0 do
      timer = Process.send_after(self(), :poll_members, config(:member_poll_ms, @default_poll_ms))
      %{state | poll_timer: timer}
    else
      state
    end
  end

  defp schedule_poll(state), do: state

  defp set_polled(state, polled) do
    if MapSet.equal?(polled, state.polled) do
      state
    else
      state = %{state | polled: polled}
      broadcast(state, {:polled, MapSet.to_list(polled)})
      state
    end
  end

  defp apply_statuses(state, statuses) do
    unavailable =
      Enum.reduce(statuses, state.live_unavailable, fn
        {z32, {:error, _}}, acc -> MapSet.put(acc, z32)
        {z32, _}, acc -> MapSet.delete(acc, z32)
      end)

    set_live_unavailable(state, unavailable)
  end

  defp set_live_unavailable(state, unavailable) do
    if MapSet.equal?(unavailable, state.live_unavailable) do
      state
    else
      state = %{state | live_unavailable: unavailable}
      broadcast(state, {:live_unavailable, MapSet.to_list(unavailable)})
      state
    end
  end

  # A definition written again while the room is an archive reopens it:
  # viewers re-attach on `:ready` and read the new status from the snapshot.
  defp update_room(%{status: :closed} = state, %Room{closed_at: nil} = room) do
    state = %{state | room: room, status: :ready}
    broadcast(state, :ready)
    state
  end

  defp update_room(state, room) do
    if room == state.room do
      state
    else
      state = %{state | room: room}
      broadcast(state, {:room_updated, room})
      state
    end
  end

  # Closing keeps the process (and its subscriptions) alive: the archive is
  # read from the same table and the idle timer decides when it stops.
  defp close(%{status: :closed} = state, _room), do: state

  defp close(state, room) do
    room = room || state.room
    room = room && %{room | closed_at: room.closed_at || System.os_time(:millisecond)}
    state = %{state | status: :closed, room: room}
    broadcast(state, :room_closed)
    state
  end

  # ── fetching ───────────────────────────────────────────────────────────────

  defp fetch_async(author, ref, msg_id, why) do
    server = self()
    key = {msg_id, author}

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      result =
        with {:ok, bytes} <- Pubky.get(author, Paths.message(ref, msg_id)) do
          Message.decode(bytes, author, ref, msg_id)
        end

      send(server, {:fetched, key, {why, result}})
    end)
  end

  defp apply_fetch(state, key, {why, {:ok, msg}}) do
    case state.pending do
      %{^key => %{at: at}} -> Telemetry.confirm(System.monotonic_time(:millisecond) - at, why)
      _ when why == :event -> Telemetry.lag(System.os_time(:millisecond) - msg.created_at)
      _ -> :ok
    end

    upsert(%{state | pending: Map.delete(state.pending, key)}, msg)
  end

  defp apply_fetch(state, key, {:verify, {:error, :not_found}}) do
    if Map.has_key?(state.pending, key) do
      broadcast(state, {:message_failed, key, :vanished})
      %{state | pending: Map.delete(state.pending, key)}
    else
      state
    end
  end

  defp apply_fetch(state, key, {why, {:error, reason}}) do
    Logger.debug("message #{inspect(key)} (#{why}) not loaded: #{inspect(reason)}")
    state
  end

  defp upsert(state, %Message{key: key} = msg) do
    msg = with_reactions(state, msg)

    changed? =
      case :ets.lookup(state.table, key) do
        [{^key, ^msg}] -> false
        _ -> true
      end

    if changed? do
      :ets.insert(state.table, {key, msg})
      broadcast(state, {:message_upserted, msg})
      Directory.touch(state.ref, msg.created_at)
    end

    state
  end

  # Bootstrap: fetch every member's newest messages before announcing :ready.
  defp backfill_sync(state, members) do
    {msgs, failed, leftovers, reactions} = fetch_history(members, state.ref, MapSet.new())
    state = Enum.reduce(msgs, state, fn msg, acc -> upsert(acc, msg) end)
    state = merge_leftovers(state, leftovers, msgs)
    state = apply_listed_reactions(state, reactions, broadcast: false)
    set_unreachable(state, MapSet.new(failed))
  end

  # Joins and retries: fetch in the background; the result comes back as
  # `{:backfilled, …}`. Messages already in the table are not fetched again.
  defp backfill_async(state, members) do
    server = self()
    ref = state.ref
    known = known_keys(state, members)

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      send(server, {:backfilled, members, fetch_history(members, ref, known)})
    end)
  end

  # Polls: exact listing (see `fetch_history/4`), result as `{:poll_result, …}`.
  # `since` is the newest id a deletion verdict may cover: a message younger
  # than one poll interval may still be in flight (written on this node by a
  # polled member whose own session brought the event) and is judged later.
  defp poll_async(state, members) do
    server = self()
    ref = state.ref
    known = known_keys(state, members)
    lag_us = config(:member_poll_ms, @default_poll_ms) * 1_000
    since = Ids.encode(max(System.os_time(:microsecond) - lag_us, 0))

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      {history, listed} = fetch_history(members, ref, known, :exact)
      send(server, {:poll_result, members, since, history, listed})
    end)
  end

  defp apply_backfill(state, members, {msgs, failed, leftovers, reactions}) do
    msgs = Enum.reject(msgs, &banned?(state, &1.author))
    state = Enum.reduce(msgs, state, fn msg, acc -> upsert(acc, msg) end)
    state = merge_leftovers(state, leftovers, msgs)
    state = apply_listed_reactions(state, reactions, broadcast: true)

    unreachable =
      state.unreachable
      |> MapSet.difference(MapSet.new(members))
      |> MapSet.union(MapSet.new(failed))

    set_unreachable(state, unreachable)
  end

  # Messages of `member` the room holds (confirmed, older than `since`, not
  # below the oldest id the poll listed) that the listing lacks are gone.
  defp apply_poll_listing(state, {member, ids}, since) do
    listed = MapSet.new(ids)
    floor = List.last(ids)

    gone =
      for {{msg_id, ^member} = key, %Message{state: :confirmed}} <-
            :ets.select(state.table, [{{{:_, member}, :_}, [], [:"$_"]}]),
          msg_id < since,
          is_nil(floor) or msg_id >= floor,
          not MapSet.member?(listed, msg_id),
          do: key

    Enum.each(gone, fn key ->
      :ets.delete(state.table, key)
      broadcast(state, {:message_deleted, key})
    end)

    older =
      case state.older[member] do
        %{entries: entries} = o ->
          kept =
            Enum.filter(entries, fn {msg_id, _} ->
              MapSet.member?(listed, msg_id) or (floor && msg_id < floor) or msg_id >= since
            end)

          Map.put(state.older, member, %{o | entries: kept})

        nil ->
          state.older
      end

    %{state | older: older, reactions: Map.drop(state.reactions, gone)}
  end

  # Keys the room already holds (in the table or as unfetched listing entries).
  defp known_keys(state, members) do
    in_table =
      for member <- members,
          msg <- :ets.select(state.table, [{{{:_, member}, :"$1"}, [], [:"$1"]}]),
          into: MapSet.new(),
          do: msg.key

    for member <- members,
        %{entries: entries} <- [state.older[member]],
        {msg_id, _path} <- entries,
        into: in_table,
        do: {msg_id, member}
  end

  defp retry_unreachable(%{unreachable: unreachable} = state) do
    if MapSet.size(unreachable) > 0, do: backfill_async(state, MapSet.to_list(unreachable))
    state
  end

  defp set_unreachable(state, unreachable) do
    state =
      if MapSet.equal?(unreachable, state.unreachable) do
        state
      else
        broadcast(state, {:unreachable, MapSet.to_list(unreachable)})
        %{state | unreachable: unreachable}
      end

    schedule_retry(state)
  end

  defp schedule_retry(%{unreachable: unreachable, retry_timer: nil} = state) do
    if MapSet.size(unreachable) > 0,
      do: %{state | retry_timer: Process.send_after(self(), :retry_history, @retry_history_every)},
      else: state
  end

  defp schedule_retry(state), do: state

  # Lists every member's folder (one request each), merges the entries by
  # message id (time-ordered), and fetches only the newest `bootstrap_messages`
  # that are not `known` already. Returns `{messages, members_whose_listing_failed,
  # leftovers, reactions}` where `leftovers` maps each listed member to the
  # entries that were not fetched (newest first) and the cursor for older ones.
  #
  # In `:exact` mode (polls) each folder is paged until an entry in `known` is
  # met and *every* new entry is fetched; the result is `{history, listed}`
  # with `listed` mapping each listed member to all ids seen, newest first.
  #
  # Cursors are captured before anything is listed: a message written after
  # the listing then always arrives through the event stream, and one written
  # before is in the listing. Overlap is idempotent.
  defp fetch_history(members, ref, known, mode \\ :page) do
    per_member = config(:bootstrap_per_member, 50)
    total = if mode == :exact, do: :infinity, else: config(:bootstrap_messages, 100)

    members
    |> Task.async_stream(&Subscriptions.capture_cursor/1,
      max_concurrency: concurrency(),
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    list =
      case mode do
        :page -> &list_recent(ref, &1, nil, per_member)
        :exact -> &list_until_known(ref, &1, known, per_member)
      end

    {listed, failed} =
      members
      |> Task.async_stream(list,
        max_concurrency: concurrency(),
        timeout: if(mode == :exact, do: 120_000, else: 30_000),
        on_timeout: :kill_task
      )
      |> Enum.zip(members)
      |> Enum.reduce({%{}, []}, fn
        {{:ok, {:ok, entries, next}}, member}, {acc, failed} ->
          {Map.put(acc, member, %{entries: entries, cursor: next}), failed}

        {_error_or_exit, member}, {acc, failed} ->
          {acc, [member | failed]}
      end)

    all_ids =
      Map.new(listed, fn {member, %{entries: entries}} ->
        {member, Enum.map(entries, &elem(&1, 0))}
      end)

    # entries the room already holds are neither fetched again nor "unfetched"
    listed =
      Map.new(listed, fn {member, %{entries: entries} = m} ->
        rest = Enum.reject(entries, fn {msg_id, _} -> MapSet.member?(known, {msg_id, member}) end)
        {member, %{m | entries: rest}}
      end)

    picks = listed |> all_entries() |> take(total)
    leftovers = without_picks(listed, picks)

    history =
      {fetch_messages(ref, picks), failed, leftovers, list_reactions(ref, Map.keys(listed))}

    case mode do
      :page -> history
      :exact -> {history, all_ids}
    end
  end

  defp take(entries, :infinity), do: entries
  defp take(entries, n), do: Enum.take(entries, n)

  # Pages down a member's folder (newest first) until a page holds an entry
  # the room already knows, the folder ends, or `@max_poll_pages` pages were
  # read (then older messages are missing until the next bootstrap; logged).
  defp list_until_known(ref, member, known, limit) do
    Enum.reduce_while(1..@max_poll_pages, {[], nil}, fn page, {acc, cursor} ->
      case list_recent(ref, member, cursor, limit) do
        {:ok, entries, next} -> poll_page(acc ++ entries, next, page, known, member)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp poll_page(acc, next, page, known, member) do
    met? = Enum.any?(acc, fn {msg_id, _} -> MapSet.member?(known, {msg_id, member}) end)

    cond do
      met? or is_nil(next) ->
        {:halt, {:ok, acc, next}}

      page == @max_poll_pages ->
        Logger.info(
          "poll reached #{@max_poll_pages} pages for one member; older messages wait for the next bootstrap"
        )

        {:halt, {:ok, acc, next}}

      true ->
        {:cont, {acc, next}}
    end
  end

  # One listing per member of their reaction markers for this room (at most
  # `reactions_per_member`); nothing is fetched. Returns the members whose
  # listing succeeded and the `{reactor, msg_key, key}` triples found.
  defp list_reactions(ref, members) do
    limit = config(:reactions_per_member, 1_000)

    members
    |> Task.async_stream(&list_member_reactions(ref, &1, limit),
      max_concurrency: concurrency(),
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {member, triples}}, {listed, acc} -> {[member | listed], triples ++ acc}
      _failed_or_exit, acc -> acc
    end)
  end

  defp list_member_reactions(ref, member, limit) do
    case retrying(fn -> Pubky.list(member, Paths.reactions_dir(ref), limit: limit) end) do
      {:ok, %{entries: entries}} ->
        triples =
          for %{path: path} <- entries,
              {:reaction, _c, _id, author, msg_id, key} <- [Paths.parse(path)],
              do: {member, {msg_id, author}, key}

        {member, triples}

      {:error, :not_found} ->
        {member, []}

      {:error, _reason} ->
        :failed
    end
  end

  # Every unfetched entry across members as `{msg_id, member, path}`, newest first.
  defp all_entries(per_member) do
    per_member
    |> Enum.flat_map(fn {member, %{entries: entries}} ->
      Enum.map(entries, fn {msg_id, path} -> {msg_id, member, path} end)
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
  end

  defp without_picks(per_member, picks) do
    picked = MapSet.new(picks, fn {msg_id, member, _} -> {msg_id, member} end)

    Map.new(per_member, fn {member, %{entries: entries} = m} ->
      rest = Enum.reject(entries, fn {msg_id, _} -> MapSet.member?(picked, {msg_id, member}) end)
      {member, %{m | entries: rest}}
    end)
  end

  defp fetch_messages(ref, picks) do
    picks
    |> Task.async_stream(
      fn {msg_id, member, path} -> load_message(ref, member, path, msg_id) end,
      max_concurrency: concurrency(),
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, msg}} -> [msg]
      _ -> []
    end)
  end

  defp concurrency, do: config(:fetch_concurrency, 16)

  # ── paging ─────────────────────────────────────────────────────────────────

  # Per member: `entries` listed but not fetched (newest first), `cursor` for
  # the page after them (nil when the folder is exhausted) and `floor`, the
  # oldest message fetched so far. Everything newer than the *boundary* — the
  # newest unfetched entry, or the floor of a member with only a cursor left —
  # is complete in the table.
  defp merge_leftovers(state, leftovers, fetched) do
    floors = Enum.group_by(fetched, & &1.author, & &1.msg_id)

    older =
      Enum.reduce(leftovers, state.older, fn {member, %{entries: entries, cursor: cursor}}, acc ->
        previous = acc[member] || %{entries: [], cursor: nil, floor: nil}
        entries = merge_entries(previous.entries, entries)
        floor = min_id(previous.floor, floors[member])

        cursor =
          if is_nil(previous.floor) and previous.entries == [], do: cursor, else: previous.cursor

        Map.put(acc, member, %{entries: entries, cursor: cursor, floor: floor})
      end)

    %{state | older: older}
  end

  defp merge_entries(old, new), do: (old ++ new) |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort(:desc)

  defp min_id(nil, nil), do: nil
  defp min_id(floor, nil), do: floor
  defp min_id(nil, ids), do: Enum.min(ids)
  defp min_id(floor, ids), do: Enum.min([floor | ids])

  defp boundary(older) do
    older
    |> Enum.map(fn
      {_member, %{entries: [{msg_id, _} | _]}} -> msg_id
      {_member, %{cursor: cursor, floor: floor}} when not is_nil(cursor) -> floor || "~"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  # Messages older than `before` from the table, but never older than the
  # boundary (below it the table may have gaps).
  defp older_from_table(state, before, limit) do
    guards =
      case boundary(state.older) do
        nil -> [{:<, :"$1", {before}}]
        bound -> [{:andalso, {:<, :"$1", {before}}, {:>, {:element, 1, :"$1"}, bound}}]
      end

    msgs =
      case :ets.select_reverse(state.table, [{{:"$1", :"$2"}, guards, [:"$2"]}], limit) do
        {msgs, _cont} -> Enum.reverse(msgs)
        :"$end_of_table" -> []
      end

    oldest = if msgs == [], do: before, else: hd(msgs).key
    more? = boundary(state.older) != nil or table_has_older?(state.table, oldest)
    {:ok, msgs, more?}
  end

  defp table_has_older?(table, key) do
    match?(
      {[_], _},
      :ets.select_reverse(table, [{{:"$1", :_}, [{:<, :"$1", {key}}], [true]}], 1)
    )
  end

  defp start_paging(%{paging: true} = state, _limit), do: state

  defp start_paging(state, limit) do
    server = self()
    %{ref: ref, older: older} = state

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      send(server, {:extended, extend_history(ref, older, limit)})
    end)

    %{state | paging: true}
  end

  # One paging round: refill members whose unfetched entries ran out (one
  # listing each, from their cursor), pick the newest `limit` entries across
  # members, fetch them. `progress?` is false when nothing could be listed or
  # fetched, so callers stop retrying.
  defp extend_history(ref, older, limit) do
    per_member = config(:bootstrap_per_member, 50)

    refilled =
      older
      |> Enum.filter(fn {_member, %{entries: entries, cursor: cursor}} ->
        entries == [] and not is_nil(cursor)
      end)
      |> Task.async_stream(
        fn {member, %{cursor: cursor}} ->
          {member, list_recent(ref, member, cursor, per_member)}
        end,
        max_concurrency: concurrency(),
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(older, fn
        {:ok, {member, {:ok, entries, next}}}, acc ->
          Map.update!(acc, member, &%{&1 | entries: entries, cursor: next})

        _failed_or_exit, acc ->
          acc
      end)

    picks = refilled |> all_entries() |> Enum.take(limit)
    msgs = fetch_messages(ref, picks)
    floors = Enum.group_by(msgs, & &1.author, & &1.msg_id)

    older =
      refilled
      |> without_picks(picks)
      |> Map.new(fn {member, m} -> {member, %{m | floor: min_id(m.floor, floors[member])}} end)

    {msgs, older, refilled != older or msgs != []}
  end

  defp insert_silently(state, %Message{key: key} = msg) do
    unless :ets.member(state.table, key),
      do: :ets.insert(state.table, {key, with_reactions(state, msg)})
  end

  # One page of a member's folder, newest first: `{:ok, [{msg_id, path}], next_cursor}`.
  defp list_recent(ref, member, cursor, limit) do
    case retrying(fn ->
           Pubky.list(member, Paths.messages_dir(ref),
             reverse: true,
             limit: limit,
             cursor: cursor
           )
         end) do
      {:ok, %{entries: entries, next_cursor: next}} ->
        {:ok,
         for(
           %{path: path} <- entries,
           {:message, _, _, msg_id} <- [Paths.parse(path)],
           do: {msg_id, path}
         ), next}

      # a member who never wrote in this room has no folder yet: nothing to load
      {:error, :not_found} ->
        {:ok, [], nil}

      {:error, reason} ->
        Logger.debug("history of #{String.slice(member, 0, 8)}… unavailable: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_message(ref, member, path, msg_id) do
    with {:ok, bytes} <- retrying(fn -> Pubky.get(member, path) end) do
      Message.decode(bytes, member, ref, msg_id)
    end
  end

  # Homeservers answer 429 with Retry-After when we read too fast: wait once, then retry.
  defp retrying(fun) do
    case fun.() do
      {:error, {:rate_limited, ms}} ->
        Process.sleep(min(ms || 1_000, 5_000))
        fun.()

      other ->
        other
    end
  end

  defp config(key, default), do: Application.get_env(:pubky_rooms, key, default)

  # ── viewers / idle ─────────────────────────────────────────────────────────

  defp maybe_start_idle_timer(%{viewers: viewers, idle_timer: nil} = state)
       when map_size(viewers) == 0 do
    timeout = if too_many_warm_rooms?(), do: 1_000, else: config(:room_idle_timeout_ms, 1_800_000)
    %{state | idle_timer: Process.send_after(self(), :idle_stop, timeout)}
  end

  defp maybe_start_idle_timer(state), do: state

  defp too_many_warm_rooms? do
    %{active: active} = DynamicSupervisor.count_children(PubkyRooms.Rooms.RoomSupervisor)
    active > config(:max_idle_rooms, 200)
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  # The viewer total is announced at most once per debounce window.
  defp viewers_changed(%{viewers_timer: nil} = state) do
    delay = config(:viewers_debounce_ms, @default_viewers_debounce)
    %{state | viewers_timer: Process.send_after(self(), :announce_viewers, delay)}
  end

  defp viewers_changed(state), do: state

  defp snapshot_of(state) do
    %{
      status: state.status,
      room: state.room,
      table: state.table,
      members: MapSet.to_list(state.members),
      unreachable: MapSet.to_list(state.unreachable),
      polled: MapSet.to_list(state.polled),
      live_unavailable: MapSet.to_list(state.live_unavailable),
      viewers: map_size(state.viewers),
      bans: Map.new(state.bans, fn {z32, %{reason: reason}} -> {z32, reason} end),
      more?: boundary(state.older) != nil or :ets.info(state.table, :size) > @history_limit
    }
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(PubkyRooms.PubSub, topic(state.ref), {:room_event, state.ref, event})
  end

  @doc "The BLAKE3 hash the homeserver will announce for these bytes."
  @spec content_hash(iodata()) :: binary()
  def content_hash(bytes), do: Blake3.hash(IO.iodata_to_binary(bytes))
end

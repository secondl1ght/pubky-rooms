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
       from this node), `DEL`s remove, join markers add and remove members,
       room definition changes update or close the room.
    3. **Idle** — with no viewers attached for `room_idle_timeout_ms` the room
       releases its subscriptions and stops (sooner when more than
       `max_idle_rooms` rooms are alive); the next visit bootstraps again.
    4. **Unreachable history** — members whose folder could not be listed are
       reported as `{:unreachable, [z32]}` (and in the snapshot) and retried
       every minute while viewers are attached, or on `retry_history/1`.
    5. **Live budget** — at most `max_members_subscribed` members (creator
       first) get event subscriptions; members beyond that are *polled*: their
       folders are re-listed every `member_poll_ms` while viewers are
       attached (`{:polled, [z32]}`). Members whose stream is down are
       reported as `{:live_unavailable, [z32]}` from `Subscriptions` status
       broadcasts. Nobody is ever dropped from a room.

  Messages live in a public ETS `ordered_set` keyed by `{msg_id, author}`,
  so viewers read history directly. Changes are broadcast on the room topic as
  `{:room_event, ref, event}`; see `PubkyRoomsWeb.RoomLive` for the consumer.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Pubky.Crypto.Blake3
  alias PubkyRooms.{Events, Pubky}
  alias PubkyRooms.Events.Subscriptions
  alias PubkyRooms.Rooms.{Directory, Message, Paths}

  @sweep_every 5_000
  @stop_after_error 30_000
  @retry_history_every 60_000
  @default_budget 5_000
  @default_poll_ms 60_000

  @type ref :: Paths.room_ref()
  @type status :: :bootstrapping | :ready | :not_found | :closed | {:error, term()}

  # ── API ────────────────────────────────────────────────────────────────────

  @doc "The PubSub topic of a room."
  @spec topic(ref()) :: String.t()
  def topic({creator, id}), do: "room:#{creator}/#{id}"

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

  @doc "Reads the newest `limit` messages from the room's ETS table, oldest first."
  @spec history(:ets.tid(), pos_integer()) :: [Message.t()]
  def history(table, limit \\ 200) do
    case :ets.select_reverse(table, [{{:_, :"$1"}, [], [:"$1"]}], limit) do
      {msgs, _cont} -> Enum.reverse(msgs)
      :"$end_of_table" -> []
    end
  end

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
      poll_timer: nil
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case Directory.fetch_room(state.ref) do
      {:ok, room} ->
        Directory.put_room(room)
        members = MapSet.new(Directory.members_of(state.ref))
        {subscribed, polled} = split_budget(state.creator, members)
        state = %{state | room: room, members: members, subscribed: subscribed, polled: polled}
        Subscriptions.acquire(subscribed, self())
        # PubSub topics are free: polled members' events still arrive when
        # anyone else on this node follows them (e.g. their own session).
        Enum.each(members, &Events.subscribe_user/1)
        Subscriptions.subscribe()
        Directory.subscribe()
        state = backfill_sync(state, members)
        state = apply_statuses(state, Subscriptions.statuses(subscribed))
        Process.send_after(self(), :sweep_pending, @sweep_every)
        state = %{state | status: :ready}
        broadcast(state, :ready)
        {:noreply, state |> maybe_start_idle_timer() |> schedule_poll()}

      {:error, :not_found} ->
        fail(state, :not_found)

      {:error, reason} ->
        fail(state, {:error, reason})
    end
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
        else: put_in(state.viewers[viewer], Process.monitor(viewer))

    {:reply, {:ok, snapshot_of(state)}, state |> cancel_idle_timer() |> schedule_poll()}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, snapshot_of(state)}, state}

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
          handle_message_event(state, type, user, msg_id, ev.content_hash)

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

        {:room_removed, ^ref} ->
          close(state)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:fetched, key, result}, state) do
    {:noreply, apply_fetch(state, key, result)}
  end

  def handle_info({:backfilled, members, {msgs, failed}}, state) do
    state = Enum.reduce(msgs, state, fn msg, acc -> upsert(acc, msg) end)

    unreachable =
      state.unreachable
      |> MapSet.difference(MapSet.new(members))
      |> MapSet.union(MapSet.new(failed))

    {:noreply, set_unreachable(state, unreachable)}
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
      backfill_async(state.ref, MapSet.to_list(state.polled))
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
    {:noreply, maybe_start_idle_timer(state)}
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
        {%{msg: msg}, pending} = Map.pop(state.pending, key)
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
    %{state | pending: Map.delete(state.pending, key)}
  end

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

      backfill_async(state.ref, [z32])
      broadcast(state, {:member_joined, z32})
      state
    end
  end

  defp remove_member(state, z32) when z32 == state.creator, do: state

  defp remove_member(state, z32) do
    if MapSet.member?(state.subscribed, z32), do: Subscriptions.release([z32], self())
    Events.unsubscribe_user(z32)
    broadcast(state, {:member_left, z32})

    state
    |> set_polled(MapSet.delete(state.polled, z32))
    |> set_live_unavailable(MapSet.delete(state.live_unavailable, z32))
    |> Map.update!(:members, &MapSet.delete(&1, z32))
    |> Map.update!(:subscribed, &MapSet.delete(&1, z32))
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

  defp update_room(state, room) do
    if room == state.room do
      state
    else
      state = %{state | room: room}
      broadcast(state, {:room_updated, room})
      state
    end
  end

  defp close(%{status: :closed} = state), do: state

  defp close(state) do
    state = %{state | status: :closed}
    broadcast(state, :room_closed)
    Process.send_after(self(), :stop, @stop_after_error)
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

  defp apply_fetch(state, key, {_why, {:ok, msg}}) do
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
    {msgs, failed} = fetch_history(members, state.ref)
    state = Enum.reduce(msgs, state, fn msg, acc -> upsert(acc, msg) end)
    set_unreachable(state, MapSet.new(failed))
  end

  # Joins and retries: fetch in the background; the result comes back as `{:backfilled, …}`.
  defp backfill_async(ref, members) do
    server = self()

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      send(server, {:backfilled, members, fetch_history(members, ref)})
    end)
  end

  defp retry_unreachable(%{unreachable: unreachable} = state) do
    if MapSet.size(unreachable) > 0, do: backfill_async(state.ref, MapSet.to_list(unreachable))
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
  # message id (time-ordered), and fetches only the newest `bootstrap_messages`.
  # Returns `{messages, members_whose_listing_failed}`.
  #
  # Cursors are captured before anything is listed: a message written after
  # the listing then always arrives through the event stream, and one written
  # before is in the listing. Overlap is idempotent.
  defp fetch_history(members, ref) do
    per_member = config(:bootstrap_per_member, 50)
    total = config(:bootstrap_messages, 100)
    concurrency = config(:fetch_concurrency, 16)

    members
    |> Task.async_stream(&Subscriptions.capture_cursor/1,
      max_concurrency: concurrency,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    {entries, failed} =
      members
      |> Task.async_stream(&list_recent(ref, &1, per_member),
        max_concurrency: concurrency,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.zip(members)
      |> Enum.reduce({[], []}, fn
        {{:ok, {:ok, entries}}, _member}, {acc, failed} -> {entries ++ acc, failed}
        {_error_or_exit, member}, {acc, failed} -> {acc, [member | failed]}
      end)

    msgs =
      entries
      |> Enum.sort_by(fn {msg_id, _member, _path} -> msg_id end, :desc)
      |> Enum.take(total)
      |> Task.async_stream(
        fn {msg_id, member, path} -> load_message(ref, member, path, msg_id) end,
        max_concurrency: concurrency,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, msg}} -> [msg]
        _ -> []
      end)

    {msgs, failed}
  end

  defp list_recent(ref, member, limit) do
    case retrying(fn ->
           Pubky.list(member, Paths.messages_dir(ref), reverse: true, limit: limit)
         end) do
      {:ok, %{entries: entries}} ->
        {:ok,
         for(
           %{path: path} <- entries,
           {:message, _, _, msg_id} <- [Paths.parse(path)],
           do: {msg_id, member, path}
         )}

      # a member who never wrote in this room has no folder yet: nothing to load
      {:error, :not_found} ->
        {:ok, []}

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

  defp snapshot_of(state) do
    %{
      status: state.status,
      room: state.room,
      table: state.table,
      members: MapSet.to_list(state.members),
      unreachable: MapSet.to_list(state.unreachable),
      polled: MapSet.to_list(state.polled),
      live_unavailable: MapSet.to_list(state.live_unavailable)
    }
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(PubkyRooms.PubSub, topic(state.ref), {:room_event, state.ref, event})
  end

  @doc "The BLAKE3 hash the homeserver will announce for these bytes."
  @spec content_hash(iodata()) :: binary()
  def content_hash(bytes), do: Blake3.hash(IO.iodata_to_binary(bytes))
end

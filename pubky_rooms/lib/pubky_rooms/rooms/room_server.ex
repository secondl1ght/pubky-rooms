defmodule PubkyRooms.Rooms.RoomServer do
  @moduledoc """
  One process per open room: the live, in-memory view of a room assembled
  from its members' homeservers.

  Lifecycle:

    1. **Bootstrap** — read the room definition from the creator's homeserver,
       acquire event subscriptions for every known member (this captures
       their cursors first, so nothing is missed), then backfill the newest
       messages of each member and become `:ready`.
    2. **Live** — apply homeserver events: message `PUT`s become fetches (or
       instant confirmations when the content hash matches a pending write
       from this node), `DEL`s remove, join markers add and remove members,
       room definition changes update or close the room.
    3. **Idle** — with no viewers attached for `room_idle_timeout_ms`, release
       the subscriptions and stop; the next visit bootstraps again.

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
      pending: %{},
      viewers: %{},
      idle_timer: nil
    }

    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case Directory.fetch_room(state.ref) do
      {:ok, room} ->
        Directory.put_room(room)
        members = MapSet.new(Directory.members_of(state.ref))
        state = %{state | room: room, members: members}
        Subscriptions.acquire(members, self())
        Enum.each(members, &Events.subscribe_user/1)
        Directory.subscribe()
        state = backfill_sync(state, members)
        Process.send_after(self(), :sweep_pending, @sweep_every)
        state = %{state | status: :ready}
        broadcast(state, :ready)
        {:noreply, maybe_start_idle_timer(state)}

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

    {:reply, {:ok, snapshot_of(state)}, cancel_idle_timer(state)}
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
    Subscriptions.release(state.members, self())
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
      Subscriptions.acquire([z32], self())
      Events.subscribe_user(z32)
      state = %{state | members: MapSet.put(state.members, z32)}
      backfill_async(state.ref, [z32])
      broadcast(state, {:member_joined, z32})
      state
    end
  end

  defp remove_member(state, z32) when z32 == state.creator, do: state

  defp remove_member(state, z32) do
    Subscriptions.release([z32], self())
    Events.unsubscribe_user(z32)
    broadcast(state, {:member_left, z32})
    %{state | members: MapSet.delete(state.members, z32)}
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
    members
    |> fetch_history(state.ref)
    |> Enum.reduce(state, fn msg, acc -> upsert(acc, msg) end)
  end

  # Joins: fetch in the background and feed messages through the normal path.
  defp backfill_async(ref, members) do
    server = self()

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      for msg <- fetch_history(members, ref),
          do: send(server, {:fetched, msg.key, {:backfill, {:ok, msg}}})
    end)
  end

  defp fetch_history(members, ref) do
    per_member = Application.get_env(:pubky_rooms, :bootstrap_per_member, 50)

    members
    |> Task.async_stream(&history_of(ref, &1, per_member),
      max_concurrency: 8,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, msgs} -> msgs
      {:exit, _} -> []
    end)
  end

  defp history_of(ref, member, limit) do
    case Pubky.list(member, Paths.messages_dir(ref), reverse: true, limit: limit) do
      {:ok, %{entries: entries}} ->
        entries
        |> Enum.reverse()
        |> Task.async_stream(&load_message(ref, member, &1.path),
          max_concurrency: 4,
          timeout: 15_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, msg}} -> [msg]
          _ -> []
        end)

      {:error, reason} ->
        Logger.debug("no history from #{String.slice(member, 0, 8)}…: #{inspect(reason)}")
        []
    end
  end

  defp load_message(ref, member, path) do
    with {:message, _, _, msg_id} <- Paths.parse(path),
         {:ok, bytes} <- Pubky.get(member, path) do
      Message.decode(bytes, member, ref, msg_id)
    end
  end

  # ── viewers / idle ─────────────────────────────────────────────────────────

  defp maybe_start_idle_timer(%{viewers: viewers, idle_timer: nil} = state)
       when map_size(viewers) == 0 do
    timeout = Application.get_env(:pubky_rooms, :room_idle_timeout_ms, 600_000)
    %{state | idle_timer: Process.send_after(self(), :idle_stop, timeout)}
  end

  defp maybe_start_idle_timer(state), do: state

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
      members: MapSet.to_list(state.members)
    }
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(PubkyRooms.PubSub, topic(state.ref), {:room_event, state.ref, event})
  end

  @doc "The BLAKE3 hash the homeserver will announce for these bytes."
  @spec content_hash(iodata()) :: binary()
  def content_hash(bytes), do: Blake3.hash(IO.iodata_to_binary(bytes))
end

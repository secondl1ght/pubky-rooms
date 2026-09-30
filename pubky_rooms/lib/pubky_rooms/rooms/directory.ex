defmodule PubkyRooms.Rooms.Directory do
  @moduledoc """
  What this node knows about rooms and who is in them.

  The directory is a cache, never the source of truth: it is rebuilt from
  homeservers through three channels and persisted in DETS so a restart keeps
  the membership it already learned.

    * `sync_user/1` lists a user's `rooms/`, `members/` and `tags/` folders
      (run when they sign in), so a node learns about a room's members and
      tags as they show up
    * homeserver events on `pubky:all` add and remove rooms, members and tags
      live
    * `put_room/1` / `add_member/2` / `add_tag/4` record this node's own
      writes immediately
    * on mainnet, Nexus (`PubkyRooms.Nexus`) is polled for rooms tagged from
      anywhere in the ecosystem and for tagger counts this node cannot see

  A room whose definition the creator deleted is not forgotten: its row gets
  a `closed_at` timestamp and its members stay, so former members still find
  it (as a read-only archive, see `PubkyRooms.Rooms.RoomServer`) while it
  leaves discovery (public list, tag filters, popular tags). Closed rooms
  nobody opened for `closed_room_ttl_ms` (90 days) are swept hourly; the
  creator writing the definition again reopens the room.

  Tables: `:rooms_directory` (`{ref, %Room{}, last_activity_at}`),
  `:room_members` (bag `{ref, z32}`), `:user_rooms` (bag `{z32, ref}`),
  `:room_tags` (bag `{ref, label, tagger}`), `:room_tag_ids`
  (`{{tagger, id}, ref, label}`, to resolve deletions) and the memory-only
  `:room_nexus_tags` (`{{ref, label}, taggers_count}`).
  Broadcasts `{:directory, event}` on the `"directory"` topic.
  """
  use GenServer

  require Logger

  alias PubkyRooms.{Events, Nexus, Pubky}
  alias PubkyRooms.Rooms.{Membership, Paths, Room}
  alias PubkyRooms.Tags.Tag

  @rooms :rooms_directory
  @members :room_members
  @user_rooms :user_rooms
  @tags :room_tags
  @tag_ids :room_tag_ids
  @nexus_tags :room_nexus_tags
  @dets :rooms_directory_dets
  @sync_throttle_ms :timer.minutes(5)
  @nexus_refresh_ms :timer.minutes(5)
  @sweep_every_ms :timer.hours(1)
  @default_closed_ttl_ms :timer.hours(24 * 90)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Subscribes the caller to directory changes."
  def subscribe, do: Phoenix.PubSub.subscribe(PubkyRooms.PubSub, "directory")

  @doc "A room by ref, or nil."
  @spec get(Paths.room_ref()) :: Room.t() | nil
  def get(ref) do
    case :ets.lookup(@rooms, ref) do
      [{^ref, room, _activity}] -> room
      [] -> nil
    end
  end

  @doc "Members known for a room (always includes the creator)."
  @spec members_of(Paths.room_ref()) :: [String.t()]
  def members_of({creator, _} = ref) do
    Enum.uniq([creator | for({^ref, z32} <- :ets.lookup(@members, ref), do: z32)])
  end

  @doc "Whether `z32` is a known member (or the creator) of the room."
  @spec member?(Paths.room_ref(), String.t()) :: boolean()
  def member?({creator, _}, creator), do: true
  def member?(ref, z32), do: :ets.match_object(@members, {ref, z32}) != []

  @doc "Number of known members."
  @spec member_count(Paths.room_ref()) :: non_neg_integer()
  def member_count(ref), do: ref |> members_of() |> length()

  @doc """
  Rooms the user created and rooms they joined, newest activity first; closed
  rooms they belonged to (either way) are listed apart under `closed`.
  """
  @spec rooms_of(String.t()) :: %{created: [Room.t()], joined: [Room.t()], closed: [Room.t()]}
  def rooms_of(z32) do
    refs = for {^z32, ref} <- :ets.lookup(@user_rooms, z32), do: ref

    rooms =
      refs
      |> Enum.map(&:ets.lookup(@rooms, &1))
      |> Enum.flat_map(fn
        [{_ref, room, activity}] -> [{room, activity}]
        [] -> []
      end)
      |> Enum.sort_by(fn {_room, activity} -> activity end, :desc)
      |> Enum.map(fn {room, _} -> room end)

    {closed, open} = Enum.split_with(rooms, &Room.closed?/1)

    %{
      created: Enum.filter(open, &(&1.creator == z32)),
      joined: Enum.reject(open, &(&1.creator == z32)),
      closed: closed
    }
  end

  @doc """
  Open public rooms known to this node (visibility `public`, not closed), most
  recent activity first, then most members; at most `limit`.
  """
  @spec public_rooms(pos_integer()) :: [Room.t()]
  def public_rooms(limit \\ 100) do
    @rooms
    |> :ets.select([{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {room, _activity} -> discoverable?(room) end)
    |> Enum.sort_by(fn {room, activity} -> {-activity, -member_count(Room.ref(room))} end)
    |> Enum.take(limit)
    |> Enum.map(fn {room, _} -> room end)
  end

  # ── tags ───────────────────────────────────────────────────────────────────

  @doc """
  The tags of a room: `[%{label, count, taggers}]`, most used first. `count`
  is the larger of what this node saw and what Nexus reports.
  """
  @spec tags_of(Paths.room_ref()) :: [
          %{label: String.t(), count: pos_integer(), taggers: [String.t()]}
        ]
  def tags_of(ref) do
    local =
      @tags
      |> :ets.lookup(ref)
      |> Enum.group_by(fn {_ref, label, _tagger} -> label end, fn {_ref, _label, tagger} ->
        tagger
      end)

    nexus =
      for {{^ref, label}, count} <- :ets.match_object(@nexus_tags, {{ref, :_}, :_}),
          into: %{},
          do: {label, count}

    (Map.keys(local) ++ Map.keys(nexus))
    |> Enum.uniq()
    |> Enum.map(fn label ->
      taggers = Map.get(local, label, [])
      %{label: label, count: max(length(taggers), Map.get(nexus, label, 0)), taggers: taggers}
    end)
    |> Enum.sort_by(fn %{label: label, count: count} -> {-count, label} end)
  end

  @doc "Labels `tagger` put on the room (as seen by this node)."
  @spec own_tags(Paths.room_ref(), String.t()) :: [String.t()]
  def own_tags(ref, tagger),
    do: for({^ref, label, ^tagger} <- :ets.lookup(@tags, ref), do: label) |> Enum.sort()

  @doc "Whether `tagger` tagged the room with `label`."
  @spec tagged_by?(Paths.room_ref(), String.t(), String.t()) :: boolean()
  def tagged_by?(ref, label, tagger), do: :ets.match_object(@tags, {ref, label, tagger}) != []

  @doc "Refs of the rooms tagged `label` by anyone this node knows of."
  @spec rooms_tagged(String.t()) :: [Paths.room_ref()]
  def rooms_tagged(label) do
    local = for {ref, ^label, _tagger} <- :ets.match_object(@tags, {:_, label, :_}), do: ref

    nexus =
      for {{ref, ^label}, _count} <- :ets.match_object(@nexus_tags, {{:_, label}, :_}), do: ref

    Enum.uniq(local ++ nexus)
  end

  @doc "The most used labels across open public rooms: `[{label, rooms}]`, at most `limit`."
  @spec popular_tags(pos_integer()) :: [{String.t(), pos_integer()}]
  def popular_tags(limit \\ 12) do
    @tags
    |> :ets.tab2list()
    |> Enum.map(fn {ref, label, _tagger} -> {ref, label} end)
    |> Enum.concat(for {{ref, label}, _count} <- :ets.tab2list(@nexus_tags), do: {ref, label})
    |> Enum.uniq()
    |> Enum.filter(fn {ref, _label} -> discoverable?(get(ref)) end)
    |> Enum.frequencies_by(fn {_ref, label} -> label end)
    |> Enum.sort_by(fn {label, rooms} -> {-rooms, label} end)
    |> Enum.take(limit)
  end

  @doc """
  Records a tag `tagger` wrote (file id `id`) on a room. `read_at:` (a native
  `System.monotonic_time/0` timestamp) says when the tag file was read; a tag
  removed at or after that moment wins over the stale read.
  """
  @spec add_tag(Paths.room_ref(), String.t(), String.t(), String.t(), keyword()) :: :ok
  def add_tag(ref, label, tagger, id, opts \\ []) do
    read_at = Keyword.get(opts, :read_at, System.monotonic_time())
    GenServer.call(__MODULE__, {:add_tag, ref, label, tagger, id, read_at})
  end

  @doc "Forgets the tag file `id` of `tagger` (whatever room and label it carried)."
  @spec remove_tag(String.t(), String.t()) :: :ok
  def remove_tag(tagger, id), do: GenServer.call(__MODULE__, {:remove_tag, tagger, id})

  @doc "Asks Nexus (when configured) for the room's tags, at most once per 5 minutes per room."
  @spec refresh_nexus_tags(Paths.room_ref()) :: :ok
  def refresh_nexus_tags(ref), do: GenServer.cast(__MODULE__, {:refresh_nexus_tags, ref})

  @doc "Pulls the Nexus resources stream now (rooms tagged anywhere in the ecosystem)."
  @spec sync_nexus() :: :ok
  def sync_nexus, do: GenServer.cast(__MODULE__, :sync_nexus)

  @doc "Newest activity timestamp (ms) known for a room."
  def last_activity(ref) do
    case :ets.lookup(@rooms, ref) do
      [{^ref, _room, activity}] -> activity
      [] -> nil
    end
  end

  @doc "Records (or updates) a room and its creator's membership."
  @spec put_room(Room.t()) :: :ok
  def put_room(%Room{} = room), do: GenServer.call(__MODULE__, {:put_room, room})

  @doc "Forgets a room (and its memberships) entirely."
  @spec remove_room(Paths.room_ref()) :: :ok
  def remove_room(ref), do: GenServer.call(__MODULE__, {:remove_room, ref})

  @doc """
  Marks a known room as closed (`closed_at` now, unless already closed): it
  keeps its members and leaves discovery. Unknown rooms are ignored.
  """
  @spec close_room(Paths.room_ref()) :: :ok
  def close_room(ref), do: GenServer.call(__MODULE__, {:close_room, ref})

  @doc """
  Forgets closed rooms with no activity (opened, touched) since `now` minus
  `closed_room_ttl_ms`; returns how many were removed. Runs hourly by itself.
  """
  @spec sweep_closed(non_neg_integer()) :: non_neg_integer()
  def sweep_closed(now \\ System.os_time(:millisecond)),
    do: GenServer.call(__MODULE__, {:sweep_closed, now})

  @doc "Records a membership."
  @spec add_member(Paths.room_ref(), String.t()) :: :ok
  def add_member(ref, z32), do: GenServer.call(__MODULE__, {:add_member, ref, z32})

  @doc "Removes a membership."
  @spec remove_member(Paths.room_ref(), String.t()) :: :ok
  def remove_member(ref, z32), do: GenServer.call(__MODULE__, {:remove_member, ref, z32})

  @doc "Bumps a room's last-activity timestamp."
  @spec touch(Paths.room_ref(), non_neg_integer()) :: :ok
  def touch(ref, at \\ System.os_time(:millisecond)),
    do: GenServer.cast(__MODULE__, {:touch, ref, at})

  @doc """
  Reads the user's `rooms/` and `members/` folders from their homeserver in
  the background (throttled to once per 5 minutes per user; `force: true`
  bypasses the throttle).
  """
  @spec sync_user(String.t(), keyword()) :: :ok
  def sync_user(z32, opts \\ []), do: GenServer.cast(__MODULE__, {:sync_user, z32, opts})

  @doc "Reads and validates a room definition from the creator's homeserver."
  @spec fetch_room(Paths.room_ref()) :: {:ok, Room.t()} | {:error, term()}
  def fetch_room({creator, id}) do
    with {:ok, bytes} <- Pubky.get(creator, Paths.room(id)) do
      Room.decode(bytes, creator, id)
    end
  end

  @doc "Clears everything (tests)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir) || Application.fetch_env!(:pubky_rooms, :data_dir)
    File.mkdir_p!(data_dir)
    file = data_dir |> Path.join("directory.dets") |> String.to_charlist()
    {:ok, dets} = :dets.open_file(@dets, file: file, type: :set)

    :ets.new(@rooms, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@members, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(@user_rooms, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(@tags, [:named_table, :public, :bag, read_concurrency: true])
    :ets.new(@tag_ids, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@nexus_tags, [:named_table, :public, :set, read_concurrency: true])
    load(dets)

    Events.subscribe_all()
    if Nexus.enabled?(), do: schedule_nexus_sync(1_000)
    Process.send_after(self(), :sweep_closed, @sweep_every_ms)
    {:ok, %{dets: dets, synced: %{}, nexus_refreshed: %{}, removed_tags: %{}}}
  end

  defp load(dets) do
    :dets.foldl(
      fn
        {{:room, ref}, room, activity}, acc ->
          insert_room(ref, normalize(room), activity)
          acc

        {{:member, ref, z32}, _joined_at}, acc ->
          insert_member(ref, z32)
          acc

        {{:tag, tagger, id}, ref, label}, acc ->
          insert_tag(ref, label, tagger, id)
          acc

        _other, acc ->
          acc
      end,
      :ok,
      dets
    )
  end

  defp schedule_nexus_sync(delay), do: Process.send_after(self(), :sync_nexus, delay)

  @impl true
  def handle_call({:put_room, room}, _from, state), do: {:reply, :ok, do_put_room(state, room)}

  def handle_call({:remove_room, ref}, _from, state),
    do: {:reply, :ok, do_remove_room(state, ref)}

  def handle_call({:close_room, ref}, _from, state),
    do: {:reply, :ok, do_close_room(state, ref)}

  def handle_call({:sweep_closed, now}, _from, state) do
    ttl = Application.get_env(:pubky_rooms, :closed_room_ttl_ms, @default_closed_ttl_ms)

    stale =
      for {ref, room, activity} <- :ets.tab2list(@rooms),
          Room.closed?(room) and activity < now - ttl,
          do: ref

    {:reply, length(stale), Enum.reduce(stale, state, &do_remove_room(&2, &1))}
  end

  def handle_call({:add_member, ref, z32}, _from, state),
    do: {:reply, :ok, do_add_member(state, ref, z32)}

  def handle_call({:remove_member, ref, z32}, _from, state),
    do: {:reply, :ok, do_remove_member(state, ref, z32)}

  def handle_call({:add_tag, ref, label, tagger, id, read_at}, _from, state),
    do: {:reply, :ok, do_add_tag(state, ref, label, tagger, id, read_at)}

  def handle_call({:remove_tag, tagger, id}, _from, state),
    do: {:reply, :ok, do_remove_tag(state, tagger, id)}

  def handle_call(:reset, _from, state) do
    for t <- [@rooms, @members, @user_rooms, @tags, @tag_ids, @nexus_tags],
        do: :ets.delete_all_objects(t)

    :ok = :dets.delete_all_objects(state.dets)
    {:reply, :ok, %{state | synced: %{}, nexus_refreshed: %{}, removed_tags: %{}}}
  end

  @impl true
  def handle_cast({:touch, ref, at}, state), do: {:noreply, do_touch(state, ref, at)}

  def handle_cast({:refresh_nexus_tags, ref}, state) do
    now = System.monotonic_time(:millisecond)
    last = state.nexus_refreshed[ref]

    if Nexus.enabled?() and (is_nil(last) or now - last > @nexus_refresh_ms) do
      Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> do_refresh_nexus_tags(ref) end)

      {:noreply,
       %{state | nexus_refreshed: remember(state.nexus_refreshed, ref, now, @nexus_refresh_ms)}}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:sync_nexus, state) do
    if Nexus.enabled?(),
      do: Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> do_sync_nexus() end)

    {:noreply, state}
  end

  def handle_cast({:sync_user, z32, opts}, state) do
    now = System.monotonic_time(:millisecond)
    last = state.synced[z32]

    if opts[:force] || is_nil(last) || now - last > @sync_throttle_ms do
      Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> do_sync_user(z32) end)
      {:noreply, %{state | synced: remember(state.synced, z32, now, @sync_throttle_ms)}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:pubky_event, %{user: user, path: path, type: type}}, state) do
    {:noreply, apply_event(state, Paths.parse(path), type, user)}
  end

  def handle_info(:sync_nexus, state) do
    if Nexus.enabled?() do
      Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> do_sync_nexus() end)
      schedule_nexus_sync(Application.get_env(:pubky_rooms, :nexus_sync_ms, @nexus_refresh_ms))
    end

    {:noreply, state}
  end

  def handle_info({:nexus_tags, ref, tags}, state) do
    {:noreply, do_put_nexus_tags(state, ref, tags)}
  end

  def handle_info(:sweep_closed, state) do
    {:reply, _removed, state} =
      handle_call({:sweep_closed, System.os_time(:millisecond)}, nil, state)

    Process.send_after(self(), :sweep_closed, @sweep_every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{dets: dets}), do: :dets.close(dets)

  # ── mutations (run inside the server) ─────────────────────────────────────

  defp apply_event(state, {:room, id}, :put, user) do
    fetch_room_async({user, id})
    state
  end

  defp apply_event(state, {:room, id}, :del, user), do: do_close_room(state, {user, id})

  defp apply_event(state, {:member, creator, id}, :put, user) do
    unless get({creator, id}), do: fetch_room_async({creator, id})
    do_add_member(state, {creator, id}, user)
  end

  defp apply_event(state, {:member, creator, id}, :del, user),
    do: do_remove_member(state, {creator, id}, user)

  # Only a member's message counts as activity: anyone can write a file whose
  # path names somebody else's room.
  defp apply_event(state, {:message, creator, id, _msg_id}, :put, user) do
    if member?({creator, id}, user),
      do: do_touch(state, {creator, id}, System.os_time(:millisecond)),
      else: state
  end

  defp apply_event(state, {:tag, id}, :put, user) do
    fetch_tag_async(user, id)
    state
  end

  defp apply_event(state, {:tag, id}, :del, user), do: do_remove_tag(state, user, id)
  defp apply_event(state, _parsed, _type, _user), do: state

  defp do_put_room(state, room) do
    ref = Room.ref(room)
    activity = last_activity(ref) || room.created_at
    insert_room(ref, room, activity)
    insert_member(ref, room.creator)

    :ok =
      :dets.insert(state.dets, [
        {{:room, ref}, room, activity},
        {{:member, ref, room.creator}, room.created_at}
      ])

    broadcast({:room_updated, room})
    state
  end

  defp do_remove_room(state, ref) do
    members = for {^ref, z32} <- :ets.lookup(@members, ref), do: z32
    :ets.delete(@rooms, ref)
    :ets.delete(@members, ref)
    for z32 <- members, do: :ets.delete_object(@user_rooms, {z32, ref})
    :ok = :dets.delete(state.dets, {:room, ref})
    for z32 <- members, do: :dets.delete(state.dets, {:member, ref, z32})

    for {key, _} <- :ets.match_object(@nexus_tags, {{ref, :_}, :_}),
        do: :ets.delete(@nexus_tags, key)

    broadcast({:room_removed, ref})
    state
  end

  # Closing keeps the row and the members; Nexus counts go (the room left
  # discovery). Already-closed rooms keep their original `closed_at`.
  defp do_close_room(state, ref) do
    case :ets.lookup(@rooms, ref) do
      [{^ref, %Room{closed_at: nil} = room, activity}] ->
        closed = %{room | closed_at: System.os_time(:millisecond)}
        insert_room(ref, closed, activity)
        :ok = :dets.insert(state.dets, {{:room, ref}, closed, activity})

        for {key, _} <- :ets.match_object(@nexus_tags, {{ref, :_}, :_}),
            do: :ets.delete(@nexus_tags, key)

        broadcast({:room_closed, closed})

      _ ->
        :ok
    end

    state
  end

  defp do_add_member(state, ref, z32) do
    if :ets.match_object(@members, {ref, z32}) == [] do
      insert_member(ref, z32)
      :ok = :dets.insert(state.dets, {{:member, ref, z32}, System.os_time(:millisecond)})
      broadcast({:member_joined, ref, z32})
    end

    state
  end

  defp do_remove_member(state, ref, z32) do
    :ets.delete_object(@members, {ref, z32})
    :ets.delete_object(@user_rooms, {z32, ref})
    :ok = :dets.delete(state.dets, {:member, ref, z32})
    broadcast({:member_left, ref, z32})
    state
  end

  # A tag file read before its deletion must not resurrect the tag: removals
  # are remembered for a while and compared with the read time.
  defp do_add_tag(state, ref, label, tagger, id, read_at) do
    stale? =
      case state.removed_tags[{tagger, id}] do
        nil -> false
        removed_at -> removed_at >= read_at
      end

    if not stale? and :ets.lookup(@tag_ids, {tagger, id}) == [] do
      insert_tag(ref, label, tagger, id)
      :ok = :dets.insert(state.dets, {{:tag, tagger, id}, ref, label})
      broadcast({:tags_updated, ref})
    end

    state
  end

  defp do_remove_tag(state, tagger, id) do
    case :ets.lookup(@tag_ids, {tagger, id}) do
      [{{^tagger, ^id}, ref, label}] ->
        :ets.delete(@tag_ids, {tagger, id})
        :ets.delete_object(@tags, {ref, label, tagger})
        :ok = :dets.delete(state.dets, {:tag, tagger, id})
        broadcast({:tags_updated, ref})

      [] ->
        :ok
    end

    remember_removal(state, {tagger, id})
  end

  # Throttle maps forget entries whose window has passed once they grow, so
  # they stay proportional to recent traffic rather than to everything seen.
  defp remember(map, key, now, window_ms) do
    map = Map.put(map, key, now)

    if map_size(map) > 1_000,
      do: :maps.filter(fn _k, at -> now - at < window_ms end, map),
      else: map
  end

  defp remember_removal(state, key) do
    now = System.monotonic_time()
    memory = System.convert_time_unit(:timer.minutes(5), :millisecond, :native)
    removed = Map.put(state.removed_tags, key, now)

    removed =
      if map_size(removed) > 1_000,
        do: :maps.filter(fn _k, at -> now - at < memory end, removed),
        else: removed

    %{state | removed_tags: removed}
  end

  # Nexus counts for a room replace the previous ones; rooms Nexus knows but
  # we do not are fetched from their creator's homeserver.
  defp do_put_nexus_tags(state, ref, tags) do
    previous = :ets.match_object(@nexus_tags, {{ref, :_}, :_})
    for {key, _} <- previous, do: :ets.delete(@nexus_tags, key)
    for %{label: label, count: count} <- tags, do: :ets.insert(@nexus_tags, {{ref, label}, count})

    current = :ets.match_object(@nexus_tags, {{ref, :_}, :_})
    if Enum.sort(current) != Enum.sort(previous), do: broadcast({:tags_updated, ref})
    unless get(ref), do: fetch_room_async(ref)
    state
  end

  # Activity orders the lobby and decides when archives are swept, and the
  # timestamps it is fed come from message bodies other people wrote: a stamp
  # from the future is clamped to now (plus clock skew) so nobody can pin a
  # room to the top of the lobby.
  @max_clock_skew_ms :timer.minutes(5)

  defp do_touch(state, ref, at) do
    at = min(at, System.os_time(:millisecond) + @max_clock_skew_ms)

    case :ets.lookup(@rooms, ref) do
      [{^ref, room, activity}] when at > activity ->
        insert_room(ref, room, at)
        :ok = :dets.insert(state.dets, {{:room, ref}, room, at})
        broadcast({:room_updated, room})

      _ ->
        :ok
    end

    state
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp fetch_room_async({creator, id} = ref) do
    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      case fetch_room(ref) do
        {:ok, room} -> put_room(room)
        {:error, :not_found} -> close_room(ref)
        {:error, reason} -> Logger.debug("room #{creator}/#{id} not fetched: #{inspect(reason)}")
      end
    end)
  end

  defp do_sync_user(z32) do
    with {:ok, %{entries: rooms}} <- Pubky.list(z32, Paths.rooms_dir(), limit: 200) do
      for %{path: path} <- rooms, {:room, id} <- [Paths.parse(path)], do: learn_room({z32, id})
    end

    with {:ok, %{entries: markers}} <- Pubky.list(z32, Paths.members_dir(), limit: 500) do
      for %{path: path} <- markers, {:member, creator, id} <- [Paths.parse(path)] do
        sync_membership(z32, {creator, id}, path)
      end
    end

    with {:ok, %{entries: tags}} <- Pubky.list(z32, Paths.tags_dir(), limit: 500) do
      for %{path: path} <- tags,
          {:tag, id} <- [Paths.parse(path)],
          :ets.lookup(@tag_ids, {z32, id}) == [] do
        learn_tag(z32, id)
      end
    end

    :ok
  end

  defp fetch_tag_async(tagger, id),
    do: Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> learn_tag(tagger, id) end)

  # Reads one tag file; only tags on rooms are recorded (the room is learned too).
  defp learn_tag(tagger, id) do
    path = Paths.tag(id)
    read_at = System.monotonic_time()

    with {:ok, bytes} <- Pubky.get(tagger, path),
         {:ok, %{room_ref: ref, label: label}} when not is_nil(ref) <- Tag.decode(bytes, path) do
      unless get(ref), do: learn_room(ref)
      add_tag(ref, label, tagger, id, read_at: read_at)
    else
      _ -> :ok
    end
  end

  # Nexus: the resources stream lists every room tagged from any app.
  defp do_sync_nexus do
    for sorting <- ["timeline", "taggers_count"],
        {:ok, resources} <- [Nexus.resources(sorting: sorting, limit: 100)],
        %{uri: uri, tags: tags} <- resources,
        {:ok, ref} <- [Paths.parse_room_uri(uri)] do
      send(__MODULE__, {:nexus_tags, ref, tags})
    end

    :ok
  end

  defp do_refresh_nexus_tags(ref) do
    case Nexus.tags_by_uri(Paths.room_uri(ref)) do
      {:ok, tags} -> send(__MODULE__, {:nexus_tags, ref, tags})
      {:error, _} -> :ok
    end
  end

  defp sync_membership(z32, ref, path) do
    with {:ok, bytes} <- Pubky.get(z32, path),
         {:ok, _} <- Membership.decode(bytes, ref) do
      unless get(ref), do: learn_room(ref)
      add_member(ref, z32)
    end
  end

  # Fetches and records a room definition; unreachable or invalid rooms are skipped.
  defp learn_room(ref) do
    case fetch_room(ref) do
      {:ok, room} -> put_room(room)
      _ -> :ok
    end
  end

  defp discoverable?(%Room{visibility: "public", closed_at: nil}), do: true
  defp discoverable?(_room), do: false

  # Rows written before a struct field existed get the field's default.
  defp normalize(%{__struct__: Room} = row), do: struct(Room, Map.delete(row, :__struct__))

  defp insert_room(ref, room, activity), do: :ets.insert(@rooms, {ref, room, activity})

  defp insert_member(ref, z32) do
    :ets.insert(@members, {ref, z32})
    :ets.insert(@user_rooms, {z32, ref})
  end

  defp insert_tag(ref, label, tagger, id) do
    :ets.insert(@tags, {ref, label, tagger})
    :ets.insert(@tag_ids, {{tagger, id}, ref, label})
  end

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(PubkyRooms.PubSub, "directory", {:directory, event})
end

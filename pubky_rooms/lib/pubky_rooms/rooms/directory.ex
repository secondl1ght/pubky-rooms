defmodule PubkyRooms.Rooms.Directory do
  @moduledoc """
  What this node knows about rooms and who is in them.

  The directory is a cache, never the source of truth: it is rebuilt from
  homeservers through three channels and persisted in DETS so a restart keeps
  the membership it already learned.

    * `sync_user/1` lists a user's `rooms/` and `members/` folders (run when
      they sign in), so a node learns about a room's members as they show up
    * homeserver events on `pubky:all` add and remove rooms and members live
    * `put_room/1` / `add_member/2` record this node's own writes immediately

  Tables: `:rooms_directory` (`{ref, %Room{}, last_activity_at}`),
  `:room_members` (bag `{ref, z32}`), `:user_rooms` (bag `{z32, ref}`).
  Broadcasts `{:directory, event}` on the `"directory"` topic.
  """
  use GenServer

  require Logger

  alias PubkyRooms.{Events, Pubky}
  alias PubkyRooms.Rooms.{Membership, Paths, Room}

  @rooms :rooms_directory
  @members :room_members
  @user_rooms :user_rooms
  @dets :rooms_directory_dets
  @sync_throttle_ms :timer.minutes(5)

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

  @doc "Rooms the user created and rooms they joined, newest activity first."
  @spec rooms_of(String.t()) :: %{created: [Room.t()], joined: [Room.t()]}
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

    %{
      created: Enum.filter(rooms, &(&1.creator == z32)),
      joined: Enum.reject(rooms, &(&1.creator == z32))
    }
  end

  @doc """
  Public rooms known to this node (visibility `public`), most recent activity
  first, then most members; at most `limit`.
  """
  @spec public_rooms(pos_integer()) :: [Room.t()]
  def public_rooms(limit \\ 100) do
    @rooms
    |> :ets.select([{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {room, _activity} -> room.visibility == "public" end)
    |> Enum.sort_by(fn {room, activity} -> {-activity, -member_count(Room.ref(room))} end)
    |> Enum.take(limit)
    |> Enum.map(fn {room, _} -> room end)
  end

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

  @doc "Forgets a room."
  @spec remove_room(Paths.room_ref()) :: :ok
  def remove_room(ref), do: GenServer.call(__MODULE__, {:remove_room, ref})

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
    load(dets)

    Events.subscribe_all()
    {:ok, %{dets: dets, synced: %{}}}
  end

  defp load(dets) do
    :dets.foldl(
      fn
        {{:room, ref}, room, activity}, acc ->
          insert_room(ref, room, activity)
          acc

        {{:member, ref, z32}, _joined_at}, acc ->
          insert_member(ref, z32)
          acc

        _other, acc ->
          acc
      end,
      :ok,
      dets
    )
  end

  @impl true
  def handle_call({:put_room, room}, _from, state), do: {:reply, :ok, do_put_room(state, room)}

  def handle_call({:remove_room, ref}, _from, state),
    do: {:reply, :ok, do_remove_room(state, ref)}

  def handle_call({:add_member, ref, z32}, _from, state),
    do: {:reply, :ok, do_add_member(state, ref, z32)}

  def handle_call({:remove_member, ref, z32}, _from, state),
    do: {:reply, :ok, do_remove_member(state, ref, z32)}

  def handle_call(:reset, _from, state) do
    for t <- [@rooms, @members, @user_rooms], do: :ets.delete_all_objects(t)
    :ok = :dets.delete_all_objects(state.dets)
    {:reply, :ok, %{state | synced: %{}}}
  end

  @impl true
  def handle_cast({:touch, ref, at}, state), do: {:noreply, do_touch(state, ref, at)}

  def handle_cast({:sync_user, z32, opts}, state) do
    now = System.monotonic_time(:millisecond)
    last = state.synced[z32]

    if opts[:force] || is_nil(last) || now - last > @sync_throttle_ms do
      Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> do_sync_user(z32) end)
      {:noreply, put_in(state.synced[z32], now)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:pubky_event, %{user: user, path: path, type: type}}, state) do
    state =
      case {Paths.parse(path), type} do
        {{:room, id}, :put} ->
          fetch_room_async({user, id})
          state

        {{:room, id}, :del} ->
          do_remove_room(state, {user, id})

        {{:member, creator, id}, :put} ->
          unless get({creator, id}), do: fetch_room_async({creator, id})
          do_add_member(state, {creator, id}, user)

        {{:member, creator, id}, :del} ->
          do_remove_member(state, {creator, id}, user)

        {{:message, creator, id, _msg_id}, :put} ->
          do_touch(state, {creator, id}, System.os_time(:millisecond))

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{dets: dets}), do: :dets.close(dets)

  # ── mutations (run inside the server) ─────────────────────────────────────

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
    broadcast({:room_removed, ref})
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

  defp do_touch(state, ref, at) do
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
        {:error, :not_found} -> remove_room(ref)
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

    :ok
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

  defp insert_room(ref, room, activity), do: :ets.insert(@rooms, {ref, room, activity})

  defp insert_member(ref, z32) do
    :ets.insert(@members, {ref, z32})
    :ets.insert(@user_rooms, {z32, ref})
  end

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(PubkyRooms.PubSub, "directory", {:directory, event})
end

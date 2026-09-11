defmodule PubkyRooms.Events.Subscriptions do
  @moduledoc """
  Reference-counted homeserver event subscriptions.

  Anything that needs a user's events (a `RoomServer` for its members, a
  signed-in LiveView for its own user) calls `acquire/2`; when the last owner
  releases a user (or dies), the subscription is dropped after a grace period.

  Users are grouped by homeserver and packed into `Pubky.Events.Stream`
  processes of at most 50 users (the homeserver limit). Resolving a user's
  homeserver and capturing their current cursor happen in tasks, so acquiring
  never blocks the caller. Events are handed to `PubkyRooms.Events.dispatch/1`.
  """
  use GenServer

  require Logger

  alias PubkyRooms.Events
  alias PubkyRooms.Events.Cursors
  alias PubkyRooms.Pubky
  alias PubkyRooms.Rooms.Paths

  @max_per_stream 50
  @detach_grace 60_000
  @retry_delay 30_000

  defmodule User do
    @moduledoc false
    defstruct owners: MapSet.new(),
              status: :resolving,
              hs: nil,
              stream: nil,
              cursor: nil,
              timer: nil
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers `owner`'s interest in the users' events."
  @spec acquire([String.t()] | MapSet.t(), pid()) :: :ok
  def acquire(users, owner \\ self()),
    do: GenServer.cast(__MODULE__, {:acquire, Enum.to_list(users), owner})

  @doc "Drops `owner`'s interest in the users' events."
  @spec release([String.t()] | MapSet.t(), pid()) :: :ok
  def release(users, owner \\ self()),
    do: GenServer.cast(__MODULE__, {:release, Enum.to_list(users), owner})

  @doc "The subscription status of a user: `:resolving`, `:attached`, `{:error, reason}` or `nil`."
  def status(user), do: GenServer.call(__MODULE__, {:status, user})

  @doc "Diagnostics: users, owners and streams."
  def info, do: GenServer.call(__MODULE__, :info)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{users: %{}, owners: %{}, streams: %{}}}
  end

  @impl true
  def handle_cast({:acquire, users, owner}, state) do
    state = monitor_owner(state, owner, users)
    {:noreply, Enum.reduce(users, state, &add_owner(&2, &1, owner))}
  end

  def handle_cast({:release, users, owner}, state) do
    {:noreply, Enum.reduce(users, state, &remove_owner(&2, &1, owner))}
  end

  @impl true
  def handle_call({:status, user}, _from, state) do
    {:reply, state.users[user] && state.users[user].status, state}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       users:
         Map.new(state.users, fn {u, e} ->
           {u, %{status: e.status, owners: MapSet.size(e.owners), stream: e.stream}}
         end),
       streams: Map.new(state.streams, fn {k, s} -> {k, MapSet.to_list(s.users)} end)
     }, state}
  end

  @impl true
  def handle_info({:resolved, user, result}, state) do
    case Map.fetch(state.users, user) do
      {:ok, %User{owners: owners} = entry} ->
        if MapSet.size(owners) > 0,
          do: {:noreply, attach(state, user, entry, result)},
          else: {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:retry, user}, state) do
    case Map.fetch(state.users, user) do
      {:ok, %User{status: {:error, _}} = entry} ->
        {:noreply, resolve(state, user, %{entry | status: :resolving})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:maybe_detach, user}, state) do
    case Map.fetch(state.users, user) do
      {:ok, %User{owners: owners} = entry} ->
        if MapSet.size(owners) == 0,
          do: {:noreply, detach(state, user, entry)},
          else: {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:maybe_stop_stream, key}, state) do
    case Map.fetch(state.streams, key) do
      {:ok, %{users: users, pid: pid}} ->
        if MapSet.size(users) == 0 do
          Pubky.stop_stream(pid)
          {:noreply, %{state | streams: Map.delete(state.streams, key)}}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:pubky_event, event}, state) do
    Events.dispatch(event)
    {:noreply, state}
  end

  def handle_info({:pubky_stream, {hs, name}, status}, state) do
    Logger.debug("stream #{inspect(name)} on #{String.slice(hs, 0, 8)}…: #{inspect(status)}")
    Phoenix.PubSub.broadcast(PubkyRooms.PubSub, "streams", {:stream_status, hs, name, status})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    cond do
      Map.has_key?(state.owners, pid) -> {:noreply, owner_down(state, pid)}
      stream_key(state, pid) -> {:noreply, stream_down(state, stream_key(state, pid), reason)}
      true -> {:noreply, state}
    end
  end

  def handle_info({ref, _task_result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── owners ─────────────────────────────────────────────────────────────────

  defp monitor_owner(state, owner, users) do
    case state.owners[owner] do
      nil ->
        ref = Process.monitor(owner)
        put_in(state.owners[owner], %{ref: ref, users: MapSet.new(users)})

      %{users: existing} = o ->
        put_in(state.owners[owner], %{o | users: MapSet.union(existing, MapSet.new(users))})
    end
  end

  defp add_owner(state, user, owner) do
    case state.users[user] do
      nil ->
        entry = %User{owners: MapSet.new([owner])}
        resolve(put_in(state.users[user], entry), user, entry)

      %User{} = entry ->
        entry = %{entry | owners: MapSet.put(entry.owners, owner)}
        entry = cancel_timer(entry)
        put_in(state.users[user], entry)
    end
  end

  defp remove_owner(state, user, owner) do
    state =
      case state.owners[owner] do
        nil ->
          state

        %{users: users} = o ->
          put_in(state.owners[owner], %{o | users: MapSet.delete(users, user)})
      end

    case state.users[user] do
      nil ->
        state

      %User{owners: owners} = entry ->
        owners = MapSet.delete(owners, owner)
        entry = %{entry | owners: owners}

        entry =
          if MapSet.size(owners) == 0 and is_nil(entry.timer),
            do: %{entry | timer: Process.send_after(self(), {:maybe_detach, user}, @detach_grace)},
            else: entry

        put_in(state.users[user], entry)
    end
  end

  defp owner_down(state, pid) do
    {%{users: users}, owners} = Map.pop(state.owners, pid)
    state = %{state | owners: owners}
    Enum.reduce(users, state, &remove_owner(&2, &1, pid))
  end

  # ── resolution and streams ────────────────────────────────────────────────

  defp resolve(state, user, entry) do
    server = self()

    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
      result =
        with {:ok, hs} <- Pubky.homeserver_of(user),
             {:ok, cursor} <- capture_cursor(user) do
          {:ok, hs, cursor}
        end

      send(server, {:resolved, user, result})
    end)

    put_in(state.users[user], %{entry | status: :resolving})
  end

  defp capture_cursor(user) do
    case Cursors.get(user) do
      nil ->
        with {:ok, cursor} <- Pubky.latest_cursor(user, Paths.namespace()) do
          Cursors.put(user, cursor)
          {:ok, cursor}
        end

      cursor ->
        {:ok, cursor}
    end
  end

  defp attach(state, user, entry, {:ok, hs, cursor}) do
    case find_or_start_stream(state, hs, user, cursor) do
      {:ok, key, state} ->
        state = update_in(state.streams[key].users, &MapSet.put(&1, user))

        put_in(state.users[user], %{
          entry
          | status: :attached,
            hs: hs,
            stream: key,
            cursor: cursor
        })

      {:error, reason, state} ->
        attach(state, user, entry, {:error, reason})
    end
  end

  defp attach(state, user, entry, {:error, reason}) do
    Logger.debug(
      "events for #{String.slice(user, 0, 8)}… unavailable: #{inspect(reason)}; retrying"
    )

    Logger.warning("a member's homeserver events are unavailable (#{inspect(reason)}); retrying")

    Process.send_after(self(), {:retry, user}, @retry_delay)
    put_in(state.users[user], %{entry | status: {:error, reason}})
  end

  defp find_or_start_stream(state, hs, user, cursor) do
    case Enum.find(state.streams, fn {{h, _}, s} ->
           h == hs and MapSet.size(s.users) < @max_per_stream
         end) do
      {key, %{pid: pid}} ->
        Pubky.add_users(pid, [{user, cursor}])
        {:ok, key, state}

      nil ->
        shard = state.streams |> Map.keys() |> Enum.count(fn {h, _} -> h == hs end)
        key = {hs, {:rooms, shard, System.unique_integer([:positive])}}

        case Pubky.start_stream(
               homeserver: hs,
               name: elem(key, 1),
               users: [{user, cursor}],
               paths: [Paths.namespace()],
               live: true,
               subscriber: self()
             ) do
          {:ok, pid} ->
            Process.monitor(pid)
            {:ok, key, put_in(state.streams[key], %{pid: pid, users: MapSet.new()})}

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  defp detach(state, user, %User{stream: key} = entry) do
    state =
      case key && state.streams[key] do
        %{pid: pid} = stream ->
          Pubky.remove_users(pid, [user])
          users = MapSet.delete(stream.users, user)

          if MapSet.size(users) == 0,
            do: Process.send_after(self(), {:maybe_stop_stream, key}, @detach_grace)

          put_in(state.streams[key], %{stream | users: users})

        _ ->
          state
      end

    _ = cancel_timer(entry)
    %{state | users: Map.delete(state.users, user)}
  end

  defp stream_down(state, key, reason) do
    {stream, streams} = Map.pop(state.streams, key)
    Logger.warning("event stream #{inspect(key)} stopped: #{inspect(reason)}")

    users =
      Enum.reduce(stream.users, state.users, fn user, users ->
        case users[user] do
          nil ->
            users

          entry ->
            Process.send_after(self(), {:retry, user}, @retry_delay)
            Map.put(users, user, %{entry | status: {:error, reason}, stream: nil})
        end
      end)

    %{state | streams: streams, users: users}
  end

  defp stream_key(state, pid) do
    Enum.find_value(state.streams, fn {key, %{pid: p}} -> p == pid && key end)
  end

  defp cancel_timer(%User{timer: nil} = entry), do: entry

  defp cancel_timer(%User{timer: timer} = entry) do
    Process.cancel_timer(timer)
    %{entry | timer: nil}
  end
end

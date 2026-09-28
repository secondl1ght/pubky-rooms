defmodule PubkyRooms.Mutes do
  @moduledoc """
  A signed-in viewer's mute list: authors whose messages and typing they do
  not want to see, in every room, on every device.

  Two sources, both on the viewer's own homeserver:

    * `/pub/pubky-rooms/mutes/<z32>` — written by Rooms (`mute/3`,
      `unmute/3`); public like every Rooms file (a private directory comes
      later, together with private rooms) and synced across devices through
      the viewer's own event stream
    * `/pub/pubky.app/mutes/<z32>` — Pubky App's mute list, honored
      **read-only**: Rooms holds no capability for that namespace, so those
      mutes are lifted in Pubky App

  Bodies are never read: the path says it all (`{"v":1,"created_at":…}` is
  written for symmetry with the other markers). Lists are cached per user in
  ETS: loaded on first use (two listings, at most `mutes_ttl_ms` old, 15 min,
  so Pubky App changes show up eventually), updated at once from Rooms mute
  events on `pubky:all`, and announced as `{:mutes_updated, z32}` on
  `topic/1`. Nothing about who mutes whom is logged or exported.
  """
  use GenServer

  require Logger

  alias PubkyRooms.{Events, Ids, Pubky, RateLimit}
  alias PubkyRooms.Rooms.Paths

  @table :mutes_cache
  @app_mutes_dir "/pub/pubky.app/mutes/"
  @default_ttl :timer.minutes(15)
  @load_timeout 5_000
  @sweep_every :timer.minutes(15)

  @type lists :: %{own: MapSet.t(String.t()), app: MapSet.t(String.t())}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "PubSub topic announcing `{:mutes_updated, z32}` for one user."
  @spec topic(String.t()) :: String.t()
  def topic(z32), do: "mutes:" <> z32

  @doc "Subscribes the caller to a user's mute changes."
  def subscribe(z32), do: Phoenix.PubSub.subscribe(PubkyRooms.PubSub, topic(z32))

  @doc "Pubky App's mute directory (read-only for Rooms)."
  def app_mutes_dir, do: @app_mutes_dir

  @doc """
  The user's mute lists, `%{own, app}`, loaded from their homeserver when not
  cached (or older than `mutes_ttl_ms`). Falls back to empty lists when the
  homeserver does not answer within #{@load_timeout} ms; the next call retries.
  """
  @spec of(String.t()) :: lists()
  def of(z32) do
    fresh_after = now() - ttl()

    case :ets.lookup(@table, z32) do
      [{^z32, lists, loaded_at}] when loaded_at > fresh_after -> lists
      _ -> load(z32)
    end
  end

  @doc """
  The cached mute lists, fresh or stale, or nil when never loaded. Never lists
  the homeserver: for the room page's disconnected first render, where a
  refresh finds the row warm and a first visit accepts a moment without it.
  """
  @spec cached(String.t()) :: %{own: MapSet.t(String.t()), app: MapSet.t(String.t())} | nil
  def cached(z32) do
    case :ets.lookup(@table, z32) do
      [{^z32, lists, _loaded_at}] -> lists
      [] -> nil
    end
  end

  @doc "Everyone the user muted, in Rooms or in Pubky App."
  @spec all(String.t()) :: MapSet.t(String.t())
  def all(z32) do
    %{own: own, app: app} = of(z32)
    MapSet.union(own, app)
  end

  @doc """
  Mutes `target` for `user` by writing a marker on the user's homeserver
  (20 per hour). The cache is updated right away; the event confirms it.
  """
  @spec mute(Pubky.sid(), String.t(), String.t()) :: :ok | {:error, term()}
  def mute(sid, user, target) when target != user do
    with true <- Ids.valid_z32?(target) || {:error, :invalid_target},
         :ok <- RateLimit.check({:mutes, sid}, 20, :timer.hours(1)),
         :ok <-
           Pubky.put(sid, Paths.mute(target), JSON.encode!(%{v: 1, created_at: os_now()})) do
      apply_change(user, target, :put)
    end
  end

  def mute(_sid, _user, _target), do: {:error, :invalid_target}

  @doc "Lifts a Rooms mute by deleting the marker (already gone counts as done)."
  @spec unmute(Pubky.sid(), String.t(), String.t()) :: :ok | {:error, term()}
  def unmute(sid, user, target) do
    case Pubky.delete(sid, Paths.mute(target)) do
      ok when ok in [:ok, {:error, :not_found}] -> apply_change(user, target, :del)
      error -> error
    end
  end

  @doc "Clears the cache (tests)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Events.subscribe_all()
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{in_flight: %{}}}
  end

  # One load per user at a time; every caller waiting for it gets the result.
  @impl true
  def handle_call({:load, z32}, from, state) do
    case state.in_flight do
      %{^z32 => waiters} ->
        {:noreply, put_in(state.in_flight[z32], [from | waiters])}

      _ ->
        server = self()

        Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
          send(server, {:loaded, z32, read_lists(z32)})
        end)

        {:noreply, put_in(state.in_flight[z32], [from])}
    end
  end

  def handle_call({:apply, user, target, type}, _from, state) do
    case :ets.lookup(@table, user) do
      [{^user, %{own: own} = lists, loaded_at}] ->
        own = if type == :put, do: MapSet.put(own, target), else: MapSet.delete(own, target)

        if own != lists.own do
          :ets.insert(@table, {user, %{lists | own: own}, loaded_at})
          broadcast(user)
        end

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | in_flight: %{}}}
  end

  @impl true
  def handle_info({:loaded, z32, lists}, state) do
    {waiters, in_flight} = Map.pop(state.in_flight, z32, [])
    :ets.insert(@table, {z32, lists, now()})
    Enum.each(waiters, &GenServer.reply(&1, lists))
    broadcast(z32)
    {:noreply, %{state | in_flight: in_flight}}
  end

  # Rooms mute markers written or deleted by any client of a cached user.
  def handle_info({:pubky_event, %{user: user, path: path, type: type}}, state) do
    case Paths.parse(path) do
      {:mute, target} -> handle_call({:apply, user, target, type}, nil, state) |> elem(2)
      _ -> state
    end
    |> then(&{:noreply, &1})
  end

  def handle_info(:sweep, state) do
    stale = now() - 4 * ttl()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", stale}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ──────────────────────────────────────────────────────────────

  defp load(z32) do
    GenServer.call(__MODULE__, {:load, z32}, @load_timeout)
  catch
    :exit, _ -> empty()
  end

  defp apply_change(user, target, type),
    do: GenServer.call(__MODULE__, {:apply, user, target, type})

  defp read_lists(z32) do
    %{
      own: list_dir(z32, Paths.mutes_dir()),
      app: list_dir(z32, @app_mutes_dir)
    }
  end

  # Every entry of a mute directory whose file name is a public key.
  defp list_dir(z32, dir) do
    case Pubky.list(z32, dir, limit: 1_000) do
      {:ok, %{entries: entries}} ->
        for %{path: path} <- entries,
            target = String.replace_prefix(path, dir, ""),
            Ids.valid_z32?(target),
            into: MapSet.new(),
            do: target

      {:error, :not_found} ->
        MapSet.new()

      {:error, reason} ->
        Logger.debug("mute list unavailable: #{inspect(reason)}")
        MapSet.new()
    end
  end

  defp empty, do: %{own: MapSet.new(), app: MapSet.new()}

  defp broadcast(z32),
    do: Phoenix.PubSub.broadcast(PubkyRooms.PubSub, topic(z32), {:mutes_updated, z32})

  defp ttl, do: Application.get_env(:pubky_rooms, :mutes_ttl_ms, @default_ttl)
  defp now, do: System.monotonic_time(:millisecond)
  defp os_now, do: System.os_time(:millisecond)
end

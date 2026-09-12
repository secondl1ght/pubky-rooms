defmodule PubkyRooms.Profiles.Cache do
  @moduledoc """
  Owns the profile ETS table and runs profile fetches.

  Fetches are deduplicated (one in flight per key) and run in tasks; results
  are written to the table with a TTL (`profile_ttl_ms`, shorter after a
  failed fetch) and broadcast as `{:profile_updated, z32, profile}` when the
  profile changed. The cache watches homeserver events for the Rooms
  nickname file and refreshes that user right away; Pubky App profile
  changes are picked up when the entry expires. Entries nobody has asked
  about for a long time are swept, so the table follows the active users
  rather than everyone ever seen.
  """
  use GenServer

  require Logger

  alias PubkyRooms.{Events, Profiles}
  alias PubkyRooms.Rooms.Paths

  @default_ttl 900_000
  @error_ttl 60_000
  @sweep_every :timer.minutes(15)
  @keep_for_ttls 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Schedules a fetch for the key unless one is already running (`force: true` ignores freshness)."
  @spec fetch(String.t(), keyword()) :: :ok
  def fetch(z32, opts \\ []), do: GenServer.cast(__MODULE__, {:fetch, z32, opts})

  @doc "Stores a profile directly (tests)."
  def put(%{pubky: z32} = profile, ttl \\ ttl()) do
    :ets.insert(Profiles.table(), {z32, profile, now(), ttl})
    :ok
  end

  @doc "Clears the cache (tests)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc "Number of cached profiles."
  def count, do: :ets.info(Profiles.table(), :size)

  @impl true
  def init(_opts) do
    :ets.new(Profiles.table(), [:named_table, :public, :set, read_concurrency: true])
    Events.subscribe_all()
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{in_flight: MapSet.new()}}
  end

  @impl true
  def handle_cast({:fetch, z32, opts}, state) do
    if MapSet.member?(state.in_flight, z32) or
         (not Keyword.get(opts, :force, false) and fresh?(z32)) do
      {:noreply, state}
    else
      server = self()

      Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn ->
        send(server, {:fetched, z32, Profiles.fetch_profile(z32)})
      end)

      {:noreply, %{state | in_flight: MapSet.put(state.in_flight, z32)}}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(Profiles.table())
    {:reply, :ok, %{state | in_flight: MapSet.new()}}
  end

  @impl true
  def handle_info({:fetched, z32, result}, state) do
    previous =
      case :ets.lookup(Profiles.table(), z32) do
        [{^z32, profile, _, _}] -> profile
        [] -> nil
      end

    case result do
      {:ok, profile} ->
        :ets.insert(Profiles.table(), {z32, profile, now(), ttl()})

        if profile != (previous || Profiles.fallback(z32)) do
          Phoenix.PubSub.broadcast(
            PubkyRooms.PubSub,
            Profiles.topic(),
            {:profile_updated, z32, profile}
          )
        end

      {:error, reason} ->
        Logger.debug("profile of #{String.slice(z32, 0, 8)}… not fetched: #{inspect(reason)}")

        :ets.insert(
          Profiles.table(),
          {z32, previous || Profiles.fallback(z32), now(), @error_ttl}
        )
    end

    {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, z32)}}
  end

  def handle_info({:pubky_event, %{user: user, path: path}}, state) do
    if Paths.parse(path) == :profile, do: fetch(user, force: true)
    {:noreply, state}
  end

  def handle_info(:sweep, state) do
    cutoff = now() - @keep_for_ttls * ttl()
    :ets.select_delete(Profiles.table(), [{{:_, :_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fresh?(z32) do
    case :ets.lookup(Profiles.table(), z32) do
      [{^z32, _profile, fetched_at, ttl}] -> now() - fetched_at <= ttl
      [] -> false
    end
  end

  defp ttl, do: Application.get_env(:pubky_rooms, :profile_ttl_ms, @default_ttl)
  defp now, do: System.monotonic_time(:millisecond)
end

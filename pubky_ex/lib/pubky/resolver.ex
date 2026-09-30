defmodule Pubky.Resolver do
  @moduledoc """
  Resolves Pubky public keys to homeservers and homeservers to HTTP base URLs.

  Two lookups are needed to talk to a user's data:

    1. the user's PKARR packet → the `_pubky` record naming their homeserver key
    2. the homeserver's PKARR packet → its ICANN endpoint (see `Pubky.Pkarr.Endpoint`),
       followed by `GET /info` to learn the features it advertises

  Results are cached in ETS with TTLs (positive `resolver_ttl`, negative
  `negative_ttl`, both from `Pubky.Config`). Concurrent misses for the same key
  are coalesced into a single fetch, and fetches run in tasks so the server
  itself never blocks on the network. Reads that hit the cache never touch the
  GenServer.
  """

  use GenServer

  require Logger

  alias Pubky.{Config, Http, PublicKey}
  alias Pubky.Pkarr.{Endpoint, Relay, SignedPacket}

  @table :pubky_resolver

  @typedoc "What a homeserver's endpoint resolves to."
  @type endpoint :: %{base_url: String.t(), features: [String.t()]}

  @type homeserver_error :: :not_found | :no_pubky_record | :invalid_target | {:relay, term()}
  @type endpoint_error ::
          :not_found | :no_icann_endpoint | :private_endpoint | {:relay, term()}

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The homeserver public key a user currently points at."
  @spec homeserver_of(PublicKey.z32(), Config.t()) ::
          {:ok, PublicKey.z32()} | {:error, homeserver_error()}
  def homeserver_of(user_z32, %Config{} = config \\ Config.get()) do
    lookup({:homeserver, user_z32}, fn -> fetch_homeserver(user_z32, config) end, config)
  end

  @doc "The ICANN base URL and advertised features of a homeserver."
  @spec endpoint_of(PublicKey.z32(), Config.t()) :: {:ok, endpoint()} | {:error, endpoint_error()}
  def endpoint_of(hs_z32, %Config{} = config \\ Config.get()) do
    lookup({:endpoint, hs_z32}, fn -> fetch_endpoint(hs_z32, config) end, config)
  end

  @doc "Resolves a user all the way to `{homeserver, base_url, features}`."
  @spec base_url_for_user(PublicKey.z32(), Config.t()) ::
          {:ok, {PublicKey.z32(), String.t(), [String.t()]}}
          | {:error, homeserver_error() | endpoint_error()}
  def base_url_for_user(user_z32, %Config{} = config \\ Config.get()) do
    with {:ok, hs} <- homeserver_of(user_z32, config),
         {:ok, %{base_url: base_url, features: features}} <- endpoint_of(hs, config) do
      {:ok, {hs, base_url, features}}
    end
  end

  @doc "Drops cached entries for a key (user or homeserver)."
  @spec invalidate(PublicKey.z32()) :: :ok
  def invalidate(z32) do
    :ets.delete(@table, {:homeserver, z32})
    :ets.delete(@table, {:endpoint, z32})
    :ok
  end

  @doc "Drops every cached entry."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── Cache ──────────────────────────────────────────────────────────────────

  defp lookup(key, fetch, config) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _ ->
        # A fetch that outlives the call budget (relays and /info all timing
        # out) is reported as an error rather than exiting the caller.
        try do
          GenServer.call(__MODULE__, {:resolve, key, fetch, config}, config.request_timeout * 3)
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
        end
    end
  end

  # ── Fetchers (run inside tasks) ────────────────────────────────────────────

  defp fetch_homeserver(user_z32, config) do
    case Relay.resolve(user_z32, config) do
      {:ok, %SignedPacket{} = sp} ->
        sp
        |> SignedPacket.resource_records("_pubky")
        |> Enum.find_value(fn
          %{rdata: {kind, %{target: target}}} when kind in [:https, :svcb] -> target
          _ -> nil
        end)
        |> case do
          nil -> {{:error, :no_pubky_record}, config.negative_ttl}
          target -> homeserver_target(target, sp, config)
        end

      {:error, reason} ->
        {{:error, reason}, config.negative_ttl}
    end
  end

  defp homeserver_target(target, sp, config) do
    case PublicKey.parse(target) do
      {:ok, hs} -> {{:ok, hs}, positive_ttl(sp, config)}
      :error -> {{:error, :invalid_target}, config.negative_ttl}
    end
  end

  defp fetch_endpoint(hs_z32, config) do
    case base_url(hs_z32, config) do
      {:ok, base_url} ->
        {{:ok, %{base_url: base_url, features: fetch_features(base_url, config)}},
         config.resolver_ttl}

      {:error, reason} ->
        {{:error, reason}, config.negative_ttl}
    end
  end

  defp base_url(hs_z32, config) do
    case Map.fetch(config.homeserver_overrides, hs_z32) do
      {:ok, base_url} ->
        {:ok, base_url}

      :error ->
        with {:ok, sp} <- Relay.resolve(hs_z32, config),
             {:ok, base_url} <- sp |> Endpoint.from_packet() |> Endpoint.icann_base_url(config),
             true <-
               Endpoint.vetted_host?(URI.parse(base_url).host || "", config) ||
                 {:error, :private_endpoint} do
          {:ok, base_url}
        end
    end
  end

  @doc false
  def fetch_features(base_url, config) do
    case Http.request(:get, base_url <> "/info", [receive_timeout: 5_000], config) do
      {:ok, %Req.Response{body: body}} ->
        case JSON.decode(body) do
          {:ok, %{"features" => features}} when is_list(features) ->
            Enum.filter(features, &is_binary/1)

          _ ->
            []
        end

      {:error, reason} ->
        Logger.debug("GET #{base_url}/info failed: #{inspect(reason)}")
        []
    end
  end

  # The packet's own TTLs shorten the cache, but never below a minute: a
  # packet published with `ttl: 0` must not turn every read into relay traffic.
  @min_positive_ttl 60_000

  defp positive_ttl(%SignedPacket{records: records}, config) do
    records
    |> Enum.map(& &1.ttl)
    |> Enum.min(fn -> config.resolver_ttl end)
    |> Kernel.*(1000)
    |> min(config.resolver_ttl)
    |> max(min(@min_positive_ttl, config.resolver_ttl))
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{in_flight: %{}}}
  end

  @impl true
  def handle_call({:resolve, key, fetch, config}, from, %{in_flight: in_flight} = state) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:reply, value, state}

      _ ->
        {:noreply, %{state | in_flight: enqueue(in_flight, key, from, fetch, config)}}
    end
  end

  defp enqueue(in_flight, key, from, fetch, config) do
    case Map.fetch(in_flight, key) do
      {:ok, {ref, waiters}} ->
        Map.put(in_flight, key, {ref, [from | waiters]})

      :error ->
        task =
          Task.Supervisor.async_nolink(Pubky.TaskSupervisor, fn -> safe_fetch(fetch, config) end)

        Map.put(in_flight, key, {task.ref, [from]})
    end
  end

  @impl true
  def handle_info({ref, {value, ttl}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {key, waiters, in_flight} = pop_in_flight(state.in_flight, ref)
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond) + ttl})
    Enum.each(waiters, &GenServer.reply(&1, value))
    {:noreply, %{state | in_flight: in_flight}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {_key, waiters, in_flight} = pop_in_flight(state.in_flight, ref)
    Enum.each(waiters, &GenServer.reply(&1, {:error, {:resolver_crash, reason}}))
    {:noreply, %{state | in_flight: in_flight}}
  end

  defp pop_in_flight(in_flight, ref) do
    {key, {^ref, waiters}} = Enum.find(in_flight, fn {_k, {r, _w}} -> r == ref end)
    {key, waiters, Map.delete(in_flight, key)}
  end

  defp safe_fetch(fetch, config) do
    fetch.()
  rescue
    e ->
      Logger.error("resolver fetch raised: #{Exception.message(e)}")
      {{:error, {:resolver_crash, e}}, config.negative_ttl}
  end
end

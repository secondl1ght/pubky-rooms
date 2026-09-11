defmodule PubkyRooms.RateLimit do
  @moduledoc """
  A fixed-window rate limiter backed by ETS.

      PubkyRooms.RateLimit.check({:msg, sid}, 5, 5_000)
      #=> :ok | {:error, {:rate_limited, retry_after_ms}}

  Counters live in a public ETS table and are bumped atomically; the process
  only owns the table and sweeps expired windows once a minute.
  """
  use GenServer

  @table :pubky_rooms_rate_limit
  @sweep_every 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Counts one hit for `key` and tells whether it is within `limit` per `window_ms`."
  @spec check(term(), pos_integer(), pos_integer()) ::
          :ok | {:error, {:rate_limited, pos_integer()}}
  def check(key, limit, window_ms) do
    now = System.os_time(:millisecond)
    bucket = div(now, window_ms)
    expires_at = (bucket + 1) * window_ms
    count = :ets.update_counter(@table, {key, bucket}, {2, 1}, {{key, bucket}, 0, expires_at})

    if count <= limit, do: :ok, else: {:error, {:rate_limited, max(expires_at - now, 1)}}
  end

  @doc "Clears every counter (tests)."
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.os_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every)
end

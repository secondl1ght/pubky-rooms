defmodule PubkyRooms.Events.Cursors do
  @moduledoc """
  The newest event cursor seen per user (ETS).

  Streams resume from these cursors after a reconnect, and `advance/2` drops
  events that were already delivered.

  The table is bounded by time, not by count: a row untouched for
  `cursor_ttl_ms` (7 days) is swept hourly. Forgetting an unfollowed user's
  cursor is safe — the next `acquire` captures "now" again, and history always
  comes from listings, never from replaying old events.
  """
  use GenServer

  @table :pubky_cursors
  @sweep_every :timer.hours(1)
  @default_ttl :timer.hours(24 * 7)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The last cursor seen for the user, or nil."
  @spec get(String.t()) :: non_neg_integer() | nil
  def get(z32) do
    case :ets.lookup(@table, z32) do
      [{^z32, cursor, _touched}] -> cursor
      [] -> nil
    end
  end

  @doc "Records `cursor` when it is newer than the stored one. Returns whether it was."
  @spec advance(String.t(), non_neg_integer()) :: boolean()
  def advance(z32, cursor) when is_integer(cursor) do
    case get(z32) do
      last when is_integer(last) and last >= cursor -> false
      _ -> :ets.insert(@table, {z32, cursor, now()})
    end
  end

  @doc "Sets the cursor unconditionally (used when capturing 'now' before a backfill)."
  @spec put(String.t(), non_neg_integer() | nil) :: :ok
  def put(_z32, nil), do: :ok

  def put(z32, cursor) when is_integer(cursor) do
    :ets.insert(@table, {z32, cursor, now()})
    :ok
  end

  @doc "How many cursors are stored."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @doc "Deletes rows untouched for longer than `cursor_ttl_ms`; returns how many."
  @spec sweep() :: non_neg_integer()
  def sweep do
    cutoff = now() - Application.get_env(:pubky_rooms, :cursor_ttl_ms, @default_ttl)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  @doc "Clears every cursor (tests)."
  def reset, do: :ets.delete_all_objects(@table)

  defp now, do: System.os_time(:millisecond)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end

defmodule PubkyRooms.Events.Cursors do
  @moduledoc """
  The newest event cursor seen per user (ETS).

  Streams resume from these cursors after a reconnect, and `advance/2` drops
  events that were already delivered.
  """
  use GenServer

  @table :pubky_cursors

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The last cursor seen for the user, or nil."
  @spec get(String.t()) :: non_neg_integer() | nil
  def get(z32) do
    case :ets.lookup(@table, z32) do
      [{^z32, cursor}] -> cursor
      [] -> nil
    end
  end

  @doc "Records `cursor` when it is newer than the stored one. Returns whether it was."
  @spec advance(String.t(), non_neg_integer()) :: boolean()
  def advance(z32, cursor) when is_integer(cursor) do
    case get(z32) do
      last when is_integer(last) and last >= cursor -> false
      _ -> :ets.insert(@table, {z32, cursor})
    end
  end

  @doc "Sets the cursor unconditionally (used when capturing 'now' before a backfill)."
  @spec put(String.t(), non_neg_integer() | nil) :: :ok
  def put(_z32, nil), do: :ok

  def put(z32, cursor) when is_integer(cursor) do
    :ets.insert(@table, {z32, cursor})
    :ok
  end

  @doc "Clears every cursor (tests)."
  def reset, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

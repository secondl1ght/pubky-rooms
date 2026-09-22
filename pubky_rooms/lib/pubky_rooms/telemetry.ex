defmodule PubkyRooms.Telemetry do
  @moduledoc """
  The app's own `:telemetry` events, and the health/capacity readings built
  from them — the whole of what this node measures about itself (ADR 0006).

  Every event carries counts and durations only. Metadata is limited to small
  bounded tags (`status`, `via`, a normalised `reason` atom); never a public
  key, session id, IP, room ref or content.

  | Event | Measurements | Metadata | When |
  |---|---|---|---|
  | `[:pubky_rooms, :stream, :connected]` | `count` | — | an event stream (re)connected |
  | `[:pubky_rooms, :stream, :disconnected]` | `count` | `reason` | a stream dropped |
  | `[:pubky_rooms, :stream, :unavailable]` | `count` | `reason` | a member's events could not be attached (retry scheduled) |
  | `[:pubky_rooms, :room, :bootstrap]` | `duration` (native), `members`, `messages` | `status` | a room finished loading |
  | `[:pubky_rooms, :message, :confirm]` | `duration` (ms) | `via` (`:event`/`:verify`) | a write from this node was confirmed by its homeserver |
  | `[:pubky_rooms, :message, :lag]` | `duration` (ms) | — | a message written elsewhere arrived through a live event (now − created_at) |
  | `[:pubky_rooms, :capacity]` | `streams`, `users`, `pool_size`, `rooms`, `directory_rooms`, `directory_members` | — | every 10 s from the poller (`measure/0`) |

  `measure/0` also logs a warning when the stream pool crosses 80 % (once per
  crossing); `health/0` feeds `GET /healthz`.
  """
  require Logger

  alias PubkyRooms.Events.Subscriptions

  @warn_at 0.8
  @clear_at 0.7
  @capacity_flag {__MODULE__, :capacity_warned}

  @doc "A stream status as `Subscriptions` receives it: `:connected`, `{:disconnected, r}` or `{:error, r}`."
  @spec stream_status(term()) :: :ok
  def stream_status(:connected),
    do: :telemetry.execute([:pubky_rooms, :stream, :connected], %{count: 1}, %{})

  def stream_status({_kind, reason}),
    do:
      :telemetry.execute([:pubky_rooms, :stream, :disconnected], %{count: 1}, %{
        reason: reason_tag(reason)
      })

  def stream_status(other),
    do:
      :telemetry.execute([:pubky_rooms, :stream, :disconnected], %{count: 1}, %{
        reason: reason_tag(other)
      })

  @doc "A member's events could not be attached (resolve or pool failure); a retry is scheduled."
  @spec stream_unavailable(term()) :: :ok
  def stream_unavailable(reason),
    do:
      :telemetry.execute([:pubky_rooms, :stream, :unavailable], %{count: 1}, %{
        reason: reason_tag(reason)
      })

  @doc "A room finished bootstrapping (`started` is a native monotonic timestamp)."
  @spec bootstrap(integer(), %{members: non_neg_integer(), messages: non_neg_integer()}, atom()) ::
          :ok
  def bootstrap(started, %{members: members, messages: messages}, status) do
    :telemetry.execute(
      [:pubky_rooms, :room, :bootstrap],
      %{duration: System.monotonic_time() - started, members: members, messages: messages},
      %{status: status}
    )
  end

  @doc "A message written from this node was confirmed `ms` after it was registered."
  @spec confirm(non_neg_integer(), :event | :verify) :: :ok
  def confirm(ms, via),
    do:
      :telemetry.execute([:pubky_rooms, :message, :confirm], %{duration: max(ms, 0)}, %{via: via})

  @doc "A message written by another client arrived through a live event; `ms` is now − created_at."
  @spec lag(integer()) :: :ok
  def lag(ms),
    do: :telemetry.execute([:pubky_rooms, :message, :lag], %{duration: max(ms, 0)}, %{})

  @doc """
  Current capacity readings: live event streams and followed users against
  the stream pool, running room servers and directory sizes.
  """
  @spec capacity() :: map()
  def capacity do
    # the poller's first run happens while the tree is still starting
    {streams, users} =
      if Process.whereis(Subscriptions),
        do: Subscriptions.info() |> then(&{map_size(&1.streams), map_size(&1.users)}),
        else: {0, 0}

    rooms =
      if Process.whereis(PubkyRooms.Rooms.Registry),
        do: Registry.count(PubkyRooms.Rooms.Registry),
        else: 0

    %{
      streams: streams,
      users: users,
      pool_size: pool_size(),
      rooms: rooms,
      directory_rooms: ets_size(:rooms_directory),
      directory_members: ets_size(:room_members)
    }
  end

  @doc "Poller entry point: emits `[:pubky_rooms, :capacity]` and warns at 80 % of the stream pool."
  @spec measure() :: :ok
  def measure do
    readings = capacity()
    :telemetry.execute([:pubky_rooms, :capacity], readings, %{})
    warn_on_capacity(readings)
  end

  @doc """
  What `GET /healthz` answers: `{:ok, body}` when every core process is up,
  `{:error, body}` (served as 503) naming the missing ones. Counts only.
  """
  @spec health() :: {:ok, map()} | {:error, map()}
  def health do
    missing =
      for name <- core_processes(), is_nil(Process.whereis(name)), do: inspect(name)

    if missing == [] do
      %{streams: streams, pool_size: pool, rooms: rooms} = capacity()
      {:ok, %{status: "ok", streams: streams, stream_pool: pool, rooms: rooms}}
    else
      {:error, %{status: "degraded", missing: missing}}
    end
  end

  @doc "The configured size of the event-stream pool (`PUBKY_STREAM_POOL_SIZE`)."
  @spec pool_size() :: pos_integer()
  def pool_size, do: Application.get_env(:pubky, :pools, []) |> Keyword.get(:streams, 100)

  @doc "Collapses any failure term to a small bounded atom usable as a metric tag."
  @spec reason_tag(term()) :: atom()
  def reason_tag(reason) when is_atom(reason), do: reason
  def reason_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  def reason_tag(_other), do: :other

  defp core_processes do
    [
      PubkyRooms.Events.Subscriptions,
      PubkyRooms.Events.Cursors,
      PubkyRooms.Rooms.Directory,
      PubkyRooms.Mutes,
      PubkyRooms.Profiles.Cache,
      PubkyRooms.Auth.SessionStore,
      PubkyRooms.RateLimit
    ]
  end

  defp warn_on_capacity(%{streams: streams, pool_size: pool}) do
    warned? = :persistent_term.get(@capacity_flag, false)

    cond do
      streams >= pool * @warn_at and not warned? ->
        Logger.warning(
          "event stream pool at #{streams} of #{pool} connections (#{round(@warn_at * 100)} %+): " <>
            "raise PUBKY_STREAM_POOL_SIZE before it fills (docs/operations.md)"
        )

        :persistent_term.put(@capacity_flag, true)

      streams < pool * @clear_at and warned? ->
        Logger.info("event stream pool back at #{streams} of #{pool} connections")
        :persistent_term.put(@capacity_flag, false)

      true ->
        :ok
    end
  end

  defp ets_size(table) do
    case :ets.info(table, :size) do
      :undefined -> 0
      n -> n
    end
  end
end

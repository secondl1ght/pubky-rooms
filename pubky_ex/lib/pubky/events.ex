defmodule Pubky.Events do
  @moduledoc """
  Homeserver event streams: start supervised `Pubky.Events.Stream` processes
  and query cursors.
  """

  alias Pubky.{Config, Http, PublicKey, Resolver}
  alias Pubky.Events.{Event, SSE, Stream}

  @doc """
  Starts a supervised stream (see `Pubky.Events.Stream` for options). The
  extra `restart:` option (default `:transient`) sets the child's restart
  strategy; a caller that recreates streams itself passes `:temporary`, so a
  crashed stream is not brought back with a stale user list behind its back.
  """
  @spec start_stream([Stream.option() | {:restart, :transient | :temporary}]) ::
          DynamicSupervisor.on_start_child()
  def start_stream(opts) do
    {restart, opts} = Keyword.pop(opts, :restart, :transient)

    DynamicSupervisor.start_child(Pubky.Events.Supervisor, %{
      id: {Stream, Keyword.fetch!(opts, :homeserver), Keyword.get(opts, :name, :default)},
      start: {Stream, :start_link, [opts]},
      restart: restart
    })
  end

  @doc "Stops every supervised stream (e.g. when the process that subscribed to them is gone)."
  @spec stop_all_streams() :: :ok
  def stop_all_streams do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Pubky.Events.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Pubky.Events.Supervisor, pid)
    end

    :ok
  end

  @doc "The pid of a running stream, if any."
  @spec whereis(PublicKey.z32(), term()) :: pid() | nil
  def whereis(homeserver, name \\ :default) do
    case Registry.lookup(Pubky.Events.Registry, {homeserver, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  The newest event cursor for `user` (optionally under `path`), or `nil` when
  the user has no events yet. Useful to capture "now" before backfilling.
  """
  @spec latest_cursor(PublicKey.z32(), PublicKey.z32(), String.t() | nil, Config.t()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def latest_cursor(homeserver, user, path \\ nil, %Config{} = config \\ Config.get()) do
    params = [user: user, reverse: true, limit: 1] ++ if(path, do: [path: path], else: [])

    with {:ok, %{base_url: base_url}} <- Resolver.endpoint_of(homeserver, config),
         opts = [
           params: params,
           headers: [{"accept", "text/event-stream"}],
           receive_timeout: 15_000
         ],
         {:ok, %{body: body}} <-
           Http.request(
             :get,
             base_url <> "/events-stream",
             Http.pubky_host(opts, homeserver),
             config
           ) do
      {:ok, newest_cursor(body, homeserver)}
    end
  end

  defp newest_cursor(body, homeserver) do
    case SSE.feed(SSE.new(), body <> "\n\n") do
      {:error, _} -> nil
      {frames, _} -> Enum.find_value(frames, &frame_cursor(&1, homeserver))
    end
  end

  defp frame_cursor(frame, homeserver) do
    case Event.from_frame(frame, homeserver) do
      {:ok, %Event{cursor: cursor}} -> cursor
      _ -> nil
    end
  end
end

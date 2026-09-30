defmodule Pubky.Events.Stream do
  @moduledoc """
  A supervised, self-healing subscription to one homeserver's `/events-stream`.

  One process per homeserver connection; it can follow up to 50 users, filter
  by path prefixes, resume from per-user cursors after any disconnect (with
  exponential backoff), and deliver `%Pubky.Events.Event{}` structs to
  subscriber processes and/or a `Phoenix.PubSub` topic:

      {:ok, pid} = Pubky.Events.start_stream(
        homeserver: hs, users: [{alice, nil}, {bob, 42}], paths: ["/pub/my-app/"],
        subscriber: self())
      receive do
        {:pubky_event, %Pubky.Events.Event{type: :put} = ev} -> ...
        {:pubky_stream, {^hs, :default}, :connected} -> ...
      end

  Messages: `{:pubky_event, event}` and `{:pubky_stream, {homeserver, name},
  :connected | {:disconnected, reason} | {:error, reason}}`. The stream stops
  with `{:error, reason}` when the homeserver rejects the subscription (4xx,
  except 429: a throttled connect is `{:disconnected, {:rate_limited, ms}}` and
  retried after its `Retry-After`, or the backoff when there is none).
  Cursors are exclusive: after reconnecting, only newer events are delivered,
  and `cursors/1` exposes the latest ones so callers can persist them. A
  stream that follows nobody (started without users, or its last user was
  removed) closes its connection and waits, without asking the homeserver for
  an empty subscription (a 400), until `add_users/2` gives it someone to follow.
  """

  use GenServer

  require Logger

  alias Pubky.{Config, Resolver, Session}
  alias Pubky.Events.{Event, SSE}

  @max_users 50
  @idle_timeout 60_000
  @min_backoff 1_000
  @max_backoff 30_000
  @reconnect_debounce 200

  @type option ::
          {:homeserver, Pubky.PublicKey.z32()}
          | {:name, term()}
          | {:users, [{Pubky.PublicKey.z32(), non_neg_integer() | nil}]}
          | {:paths, [String.t()]}
          | {:live, boolean()}
          | {:limit, pos_integer() | nil}
          | {:subscriber, pid() | [pid()]}
          | {:pubsub, {module(), String.t()} | nil}
          | {:session, Session.t() | nil}
          | {:config, Config.t()}

  # ── API ────────────────────────────────────────────────────────────────────

  @doc "Starts a stream process (use `Pubky.Events.start_stream/1` for supervision)."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    homeserver = Keyword.fetch!(opts, :homeserver)
    name = Keyword.get(opts, :name, :default)
    GenServer.start_link(__MODULE__, opts, name: via(homeserver, name))
  end

  @doc "Registry name for a stream."
  def via(homeserver, name), do: {:via, Registry, {Pubky.Events.Registry, {homeserver, name}}}

  @doc "Adds users (with optional resume cursors); reconnects to apply."
  @spec add_users(GenServer.server(), [{Pubky.PublicKey.z32(), non_neg_integer() | nil}]) ::
          :ok | {:error, :too_many_users}
  def add_users(server, users), do: GenServer.call(server, {:add_users, users})

  @doc "Removes users; reconnects to apply, or closes the connection when nobody is left."
  @spec remove_users(GenServer.server(), [Pubky.PublicKey.z32()]) :: :ok
  def remove_users(server, users), do: GenServer.call(server, {:remove_users, users})

  @doc "The latest cursor seen per user."
  @spec cursors(GenServer.server()) :: %{Pubky.PublicKey.z32() => non_neg_integer() | nil}
  def cursors(server), do: GenServer.call(server, :cursors)

  @doc "Stops the stream."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    users = Map.new(Keyword.get(opts, :users, []))

    if map_size(users) > @max_users,
      do: raise(ArgumentError, "at most #{@max_users} users per stream")

    state = %{
      homeserver: Keyword.fetch!(opts, :homeserver),
      name: Keyword.get(opts, :name, :default),
      users: users,
      paths: Keyword.get(opts, :paths, []),
      live: Keyword.get(opts, :live, true),
      limit: Keyword.get(opts, :limit),
      subscribers: List.wrap(Keyword.get(opts, :subscriber, [])),
      pubsub: Keyword.get(opts, :pubsub),
      session: Keyword.get(opts, :session),
      config: Keyword.get(opts, :config, Config.get()),
      base_url: nil,
      resp: nil,
      parser: SSE.new(),
      backoff: @min_backoff,
      idle_timer: nil,
      reconnect_timer: nil,
      connected_at: nil,
      last_uptime: 0,
      received: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call({:add_users, users}, _from, state) do
    merged = Map.merge(state.users, Map.new(users), fn _k, old, new -> new || old end)

    if map_size(merged) > @max_users do
      {:reply, {:error, :too_many_users}, state}
    else
      {:reply, :ok, schedule_reconnect(%{state | users: merged})}
    end
  end

  def handle_call({:remove_users, users}, _from, state) do
    state = %{state | users: Map.drop(state.users, users)}

    if map_size(state.users) == 0,
      do: {:reply, :ok, state |> cancel_reconnect() |> close_without_users()},
      else: {:reply, :ok, schedule_reconnect(state)}
  end

  def handle_call(:cursors, _from, state), do: {:reply, state.users, state}

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, connect(%{state | reconnect_timer: nil})}

  def handle_info(:idle_timeout, state) do
    Logger.warning(
      "event stream #{inspect(state.name)} idle for #{@idle_timeout}ms, reconnecting"
    )

    {:noreply, state |> disconnect({:disconnected, :idle}) |> backoff_reconnect()}
  end

  def handle_info(message, %{resp: %Req.Response{} = resp} = state) do
    case Req.parse_message(resp, message) do
      {:ok, chunks} ->
        {:noreply, Enum.reduce(chunks, state, &handle_chunk/2)}

      {:error, reason} ->
        {:noreply, state |> disconnect({:disconnected, reason}) |> backoff_reconnect()}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel(state)
    :ok
  end

  # ── connection lifecycle ───────────────────────────────────────────────────

  # nothing to follow: the homeserver rejects a subscription without users, so
  # wait for add_users/2 instead
  defp connect(%{users: users} = state) when map_size(users) == 0, do: cancel(state)

  defp connect(state) do
    state = cancel(state)

    with {:ok, base_url} <- base_url(state),
         {:ok, resp} <- open(state, base_url) do
      notify(state, {:pubky_stream, {state.homeserver, state.name}, :connected})

      %{
        state
        | base_url: base_url,
          resp: resp,
          parser: SSE.new(),
          connected_at: System.monotonic_time(:millisecond)
      }
      |> reset_idle()
    else
      {:error, {:rejected, status, body}} ->
        notify(
          state,
          {:pubky_stream, {state.homeserver, state.name}, {:error, {:http, status, body}}}
        )

        exit({:shutdown, {:http, status, body}})

      {:error, {:rate_limited, retry_after} = reason} ->
        notify(state, {:pubky_stream, {state.homeserver, state.name}, {:disconnected, reason}})
        backoff_reconnect(state, retry_after || 0)

      {:error, reason} ->
        notify(state, {:pubky_stream, {state.homeserver, state.name}, {:disconnected, reason}})
        backoff_reconnect(state)
    end
  end

  defp base_url(%{base_url: url}) when is_binary(url), do: {:ok, url}

  defp base_url(state) do
    case Resolver.endpoint_of(state.homeserver, state.config) do
      {:ok, %{base_url: url}} -> {:ok, url}
      {:error, reason} -> {:error, {:resolve, reason}}
    end
  end

  defp open(state, base_url) do
    headers =
      [{"accept", "text/event-stream"}, {"pubky-host", state.homeserver}] ++ auth_headers(state)

    request =
      Req.new(
        url: base_url <> "/events-stream",
        params: params(state),
        headers: headers,
        finch: [name: state.config.stream_finch],
        receive_timeout: @idle_timeout,
        retry: false,
        decode_body: false,
        into: :self
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200} = resp} ->
        {:ok, resp}

      # throttled (per client address): not a rejection, retry after the delay
      {:ok, %Req.Response{status: 429} = resp} ->
        retry_after = Pubky.Http.retry_after_ms(resp)
        drain(resp)
        {:error, {:rate_limited, retry_after}}

      {:ok, %Req.Response{status: status} = resp} ->
        body = drain(resp)

        if status in 400..499,
          do: {:error, {:rejected, status, body}},
          else: {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp params(state) do
    users =
      Enum.map(state.users, fn
        {z32, nil} -> {:user, z32}
        {z32, cursor} -> {:user, "#{z32}:#{cursor}"}
      end)

    paths = Enum.map(state.paths, &{:path, &1})
    live = if state.live, do: [live: true], else: []
    limit = if state.limit, do: [limit: state.limit], else: []
    users ++ paths ++ live ++ limit
  end

  defp auth_headers(%{session: %Session{token: token}}),
    do: [{"authorization", "Bearer " <> token}]

  defp auth_headers(_), do: []

  # Reads whatever the server sent with a non-200 status, then cancels.
  defp drain(resp) do
    Req.cancel_async_response(resp)
    ""
  end

  defp handle_chunk({:data, data}, state) do
    case SSE.feed(state.parser, data) do
      {:error, reason} ->
        state |> disconnect({:disconnected, reason}) |> backoff_reconnect()

      {frames, parser} ->
        state = %{state | parser: parser} |> reset_idle()
        Enum.reduce(frames, state, &handle_frame/2)
    end
  end

  defp handle_chunk(:done, state) do
    state = disconnect(state, {:disconnected, :closed})

    if state.live or reached_limit?(state) == false do
      backoff_reconnect(state)
    else
      exit(:normal)
    end
  end

  defp handle_chunk(_other, state), do: state

  defp reached_limit?(%{limit: nil}), do: false
  defp reached_limit?(%{limit: limit, received: n}), do: n >= limit

  defp handle_frame(frame, state) do
    case Event.from_frame(frame, state.homeserver) do
      {:ok, %Event{user: user, cursor: cursor} = event} ->
        if newer?(state.users[user], cursor) do
          notify(state, {:pubky_event, event})
          %{state | users: Map.put(state.users, user, cursor), received: state.received + 1}
        else
          state
        end

      {:error, reason} ->
        Logger.debug("ignoring event frame from #{state.homeserver}: #{inspect(reason)}")
        state
    end
  end

  defp newer?(nil, _cursor), do: true
  defp newer?(last, cursor), do: cursor > last

  defp close_without_users(%{resp: nil} = state), do: state
  defp close_without_users(state), do: disconnect(state, {:disconnected, :no_users})

  defp disconnect(state, reason) do
    notify(state, {:pubky_stream, {state.homeserver, state.name}, reason})
    uptime = if state.connected_at, do: System.monotonic_time(:millisecond) - state.connected_at
    cancel(%{state | connected_at: nil, last_uptime: uptime || state.last_uptime})
  end

  defp cancel(%{resp: %Req.Response{} = resp} = state) do
    Req.cancel_async_response(resp)
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | resp: nil, idle_timer: nil}
  end

  defp cancel(state), do: state

  # The delay grows while connections keep failing or dying young; a
  # connection that stayed up longer than the longest delay resets it, so a
  # homeserver that accepts and immediately closes cannot make us hammer it,
  # and a healthy stream that drops after hours comes back promptly.
  defp backoff_reconnect(state, at_least \\ 0) do
    state = cancel_reconnect(state)
    backoff = if state.last_uptime >= @max_backoff, do: @min_backoff, else: state.backoff
    jitter = :rand.uniform(div(backoff, 5) + 1)
    timer = Process.send_after(self(), :reconnect, max(backoff + jitter, at_least))
    %{state | reconnect_timer: timer, backoff: min(backoff * 2, @max_backoff), last_uptime: 0}
  end

  defp cancel_reconnect(%{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect(%{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end

  defp schedule_reconnect(%{reconnect_timer: nil} = state) do
    state = if state.resp, do: disconnect(state, {:disconnected, :resubscribe}), else: state
    %{state | reconnect_timer: Process.send_after(self(), :reconnect, @reconnect_debounce)}
  end

  defp schedule_reconnect(state), do: state

  defp reset_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle_timeout, @idle_timeout)}
  end

  defp notify(state, message) do
    Enum.each(state.subscribers, &send(&1, message))

    case state.pubsub do
      {mod, topic} when is_atom(mod) and is_binary(topic) -> mod.broadcast(topic, message)
      _ -> :ok
    end
  end
end

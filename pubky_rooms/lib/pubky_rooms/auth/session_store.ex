defmodule PubkyRooms.Auth.SessionStore do
  @moduledoc """
  Login sessions: the only place credentials live.

  A session id (`sid`) is an opaque random string stored in the browser
  cookie. For each sid this store keeps the durable Pubky credential (grant +
  client secret, encrypted with a key derived from `secret_key_base`) in a DETS
  file, and a hydrated `%Pubky.Session{}` (with its one-hour bearer token) in
  ETS. Sessions survive restarts: the first use after boot mints a fresh
  bearer from the credential.

  `call/2` is the way to make authenticated requests: it runs the function
  with a fresh session, writes back a refreshed token, and forgets the
  session when the homeserver reports the grant as revoked.
  """
  use GenServer

  require Logger

  alias Pubky.Session

  @table :pubky_sessions
  @dets :pubky_sessions_dets
  @sweep_every :timer.hours(1)
  @touch_every :timer.minutes(5)
  @hydrate_timeout 20_000

  @type sid :: String.t()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Stores a session and returns its new sid."
  @spec put(Session.t()) :: sid()
  def put(%Session{} = session), do: GenServer.call(__MODULE__, {:put, session})

  @doc "The session for a sid, hydrating it from the credential if needed."
  @spec lookup(term()) :: {:ok, Session.t()} | :error
  def lookup(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, %Session{} = session, _meta}] -> {:ok, session}
      [{^sid, nil, _meta}] -> GenServer.call(__MODULE__, {:hydrate, sid}, @hydrate_timeout)
      [] -> :error
    end
  end

  def lookup(_), do: :error

  @doc "The user (z32) behind a sid, without hydrating. Cheap."
  @spec user_of(term()) :: String.t() | nil
  def user_of(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, _session, %{user: user}}] -> user
      [] -> nil
    end
  end

  def user_of(_), do: nil

  @doc """
  Runs `fun.(session)` with a fresh session (see `Pubky.Session.call/3`),
  keeps the refreshed session, and drops the sid when the grant was revoked.
  """
  @spec call(sid(), (Session.t() -> term())) :: {:ok, term()} | {:error, term()}
  def call(sid, fun) when is_function(fun, 1) do
    case lookup(sid) do
      {:ok, session} ->
        case Session.call(session, fun) do
          {:ok, result, fresh} ->
            keep(sid, session, fresh)
            {:ok, result}

          {:error, :grant_revoked, _} ->
            delete(sid)
            {:error, :grant_revoked}

          {:error, reason, fresh} ->
            keep(sid, session, fresh)
            {:error, reason}
        end

      :error ->
        {:error, :no_session}
    end
  end

  @doc "Marks the session as recently used (throttled)."
  @spec touch(sid()) :: :ok
  def touch(sid) when is_binary(sid), do: GenServer.cast(__MODULE__, {:touch, sid})
  def touch(_), do: :ok

  @doc "Forgets a session and revokes its bearer on the homeserver (best effort)."
  @spec delete(sid()) :: :ok
  def delete(sid) when is_binary(sid), do: GenServer.call(__MODULE__, {:delete, sid})
  def delete(_), do: :ok

  @doc "Number of stored sessions."
  def count, do: :ets.info(@table, :size)

  defp keep(_sid, %Session{token: t}, %Session{token: t}), do: :ok
  defp keep(sid, _old, fresh), do: GenServer.cast(__MODULE__, {:update, sid, fresh})

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir) || Application.fetch_env!(:pubky_rooms, :data_dir)
    File.mkdir_p!(data_dir)
    file = data_dir |> Path.join("sessions.dets") |> String.to_charlist()
    {:ok, dets} = :dets.open_file(@dets, file: file, type: :set)
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    :dets.foldl(
      fn {sid, meta}, acc -> :ets.insert(@table, {sid, nil, meta}) && acc end,
      :ok,
      dets
    )

    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{dets: dets, keys: keys()}}
  end

  @impl true
  def handle_call({:put, session}, _from, state) do
    sid = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    now = System.os_time(:second)

    meta = %{
      user: session.user,
      homeserver: session.homeserver,
      credential: encrypt(Session.export(session), state.keys),
      created_at: now,
      last_seen_at: now
    }

    :ok = :dets.insert(state.dets, {sid, meta})
    :ets.insert(@table, {sid, session, meta})
    {:reply, sid, state}
  end

  def handle_call({:hydrate, sid}, _from, state) do
    case :ets.lookup(@table, sid) do
      [{^sid, %Session{} = session, _}] ->
        {:reply, {:ok, session}, state}

      [{^sid, nil, meta}] ->
        {:reply, hydrate(sid, meta, state), state}

      [] ->
        {:reply, :error, state}
    end
  end

  def handle_call({:delete, sid}, _from, state) do
    case :ets.lookup(@table, sid) do
      [{^sid, session, _meta}] ->
        :ets.delete(@table, sid)
        :ok = :dets.delete(state.dets, sid)
        signout_async(session)

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:update, sid, %Session{} = session}, state) do
    case :ets.lookup(@table, sid) do
      [{^sid, _old, meta}] -> :ets.insert(@table, {sid, session, meta})
      [] -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:touch, sid}, state) do
    now = System.os_time(:second)

    case :ets.lookup(@table, sid) do
      [{^sid, session, %{last_seen_at: seen} = meta}] when now - seen > div(@touch_every, 1000) ->
        meta = %{meta | last_seen_at: now}
        :ets.insert(@table, {sid, session, meta})
        :ok = :dets.insert(state.dets, {sid, meta})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    max_idle = Application.get_env(:pubky_rooms, :session_max_idle_days, 30) * 86_400
    cutoff = System.os_time(:second) - max_idle

    for {sid, _session, %{last_seen_at: seen}} <- :ets.tab2list(@table), seen < cutoff do
      :ets.delete(@table, sid)
      :dets.delete(state.dets, sid)
    end

    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{dets: dets}), do: :dets.close(dets)

  defp hydrate(sid, meta, state) do
    with {:ok, exported} <- decrypt(meta.credential, state.keys),
         {:ok, session} <- Session.restore(exported) do
      :ets.insert(@table, {sid, session, meta})
      {:ok, session}
    else
      {:error, reason} when reason in [:grant_revoked, :expired, :cnf_mismatch] ->
        Logger.info("session #{String.slice(sid, 0, 6)}… dropped: #{inspect(reason)}")
        :ets.delete(@table, sid)
        :dets.delete(state.dets, sid)
        :error

      {:error, {:http, status, _}} when status in [401, 403] ->
        :ets.delete(@table, sid)
        :dets.delete(state.dets, sid)
        :error

      other ->
        Logger.warning(
          "session #{String.slice(sid, 0, 6)}… could not be restored: #{inspect(other)}"
        )

        :error
    end
  end

  defp signout_async(%Session{} = session) do
    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> Session.signout(session) end)
  end

  defp signout_async(_), do: :ok

  defp keys do
    secret = Application.fetch_env!(:pubky_rooms, PubkyRoomsWeb.Endpoint)[:secret_key_base]

    {Plug.Crypto.KeyGenerator.generate(secret, "pubky-rooms session credentials", length: 32),
     Plug.Crypto.KeyGenerator.generate(secret, "pubky-rooms session credentials signing",
       length: 32
     )}
  end

  defp encrypt(plain, {key, sign}), do: Plug.Crypto.MessageEncryptor.encrypt(plain, key, sign)

  defp decrypt(cipher, {key, sign}) do
    case Plug.Crypto.MessageEncryptor.decrypt(cipher, key, sign) do
      {:ok, plain} -> {:ok, plain}
      :error -> {:error, :undecryptable}
    end
  end
end

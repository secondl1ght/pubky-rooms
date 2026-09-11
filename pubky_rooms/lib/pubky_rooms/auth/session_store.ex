defmodule PubkyRooms.Auth.SessionStore do
  @moduledoc """
  Login sessions, held in memory only.

  **The credential lives in the user's browser, not on this server.** After a
  Pubky Ring sign-in the durable credential (grant + client secret, scoped to
  `/pub/pubky-rooms/`) is written into the encrypted, signed, httpOnly session
  cookie. This store is a memory cache keyed by an opaque session id (`sid`):

    * `put/1` records a fresh session right after sign-in and returns its sid;
      `cookie_session/1` gives the map the controller writes into the cookie
    * `ensure/1` re-seeds the cache from a cookie on any request (so sessions
      survive restarts without anything on disk)
    * `lookup/1` hydrates a bearer token from the credential on first use;
      `call/2` runs authenticated requests and keeps refreshed tokens

  Entries unused for `session_memory_ttl_ms` are dropped; the next request
  from that browser re-seeds them. Nothing is persisted. The only way to
  escalate is to compromise the running server while a user is connected, and
  even then only within the Rooms namespace, until they revoke in Ring.
  """
  use GenServer

  require Logger

  alias Pubky.Auth.Credential
  alias Pubky.Session

  @table :pubky_sessions
  @sweep_every :timer.minutes(5)
  @hydrate_timeout 20_000

  @type sid :: String.t()
  @type cookie_session :: %{String.t() => String.t()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Caches a freshly minted session and returns its new sid."
  @spec put(Session.t()) :: sid()
  def put(%Session{} = session) do
    sid = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    insert(sid, session.user, Session.export(session), session)
    sid
  end

  @doc "The values to store in the browser session cookie for a sid, or nil."
  @spec cookie_session(sid()) :: cookie_session() | nil
  def cookie_session(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, %{user: user, export: export}}] ->
        %{"sid" => sid, "pubky" => user, "cred" => export}

      [] ->
        nil
    end
  end

  @doc """
  Re-seeds the cache from a browser session (cookie values). Returns the sid
  when the values are well-formed, nil otherwise. Cheap: no network.
  """
  @spec ensure(map()) :: sid() | nil
  def ensure(%{"sid" => sid, "pubky" => user, "cred" => export})
      when is_binary(sid) and is_binary(user) and is_binary(export) do
    cond do
      :ets.member(@table, sid) -> sid
      match?({:ok, _}, Credential.import(export)) and insert_new(sid, user, export) -> sid
      true -> nil
    end
  end

  def ensure(_), do: nil

  @doc "The session for a sid, hydrating a bearer from the credential if needed."
  @spec lookup(term()) :: {:ok, Session.t()} | :error
  def lookup(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, %{session: %Session{} = session}}] -> {:ok, session}
      [{^sid, %{session: nil}}] -> GenServer.call(__MODULE__, {:hydrate, sid}, @hydrate_timeout)
      [] -> :error
    end
  end

  def lookup(_), do: :error

  @doc "The user (z32) behind a sid, without hydrating. Cheap."
  @spec user_of(term()) :: String.t() | nil
  def user_of(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, %{user: user}}] -> user
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
        touch(sid)

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

  @doc "Marks the session as recently used."
  @spec touch(sid()) :: :ok
  def touch(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, entry}] -> :ets.insert(@table, {sid, %{entry | last_used: now()}})
      [] -> :ok
    end

    :ok
  end

  def touch(_), do: :ok

  @doc "Forgets a session and revokes its bearer on the homeserver (best effort)."
  @spec delete(sid()) :: :ok
  def delete(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, %{session: session}}] ->
        :ets.delete(@table, sid)
        signout_async(session)

      [] ->
        :ok
    end

    :ok
  end

  def delete(_), do: :ok

  @doc "Number of cached sessions."
  def count, do: :ets.info(@table, :size)

  defp keep(_sid, %Session{token: t}, %Session{token: t}), do: :ok
  defp keep(sid, _old, fresh), do: GenServer.cast(__MODULE__, {:update, sid, fresh})

  defp insert(sid, user, export, session) do
    :ets.insert(@table, {sid, %{user: user, export: export, session: session, last_used: now()}})
  end

  defp insert_new(sid, user, export) do
    :ets.insert_new(@table, {sid, %{user: user, export: export, session: nil, last_used: now()}})
  end

  defp now, do: System.monotonic_time(:millisecond)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:hydrate, sid}, _from, state) do
    case :ets.lookup(@table, sid) do
      [{^sid, %{session: %Session{} = session}}] -> {:reply, {:ok, session}, state}
      [{^sid, %{session: nil} = entry}] -> {:reply, hydrate(sid, entry), state}
      [] -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_cast({:update, sid, %Session{} = session}, state) do
    case :ets.lookup(@table, sid) do
      [{^sid, entry}] -> :ets.insert(@table, {sid, %{entry | session: session}})
      [] -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    ttl = Application.get_env(:pubky_rooms, :session_memory_ttl_ms, 7_200_000)
    cutoff = now() - ttl

    for {sid, %{last_used: used}} <- :ets.tab2list(@table), used < cutoff do
      :ets.delete(@table, sid)
    end

    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp hydrate(sid, %{export: export} = entry) do
    with {:ok, credential} <- Credential.import(export),
         {:ok, session} <- Credential.restore(credential) do
      :ets.insert(@table, {sid, %{entry | session: session, last_used: now()}})
      {:ok, session}
    else
      {:error, reason} when reason in [:grant_revoked, :expired, :cnf_mismatch] ->
        Logger.info("session #{String.slice(sid, 0, 6)}… dropped: #{inspect(reason)}")
        :ets.delete(@table, sid)
        :error

      {:error, {:http, status, _}} when status in [401, 403] ->
        :ets.delete(@table, sid)
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
end

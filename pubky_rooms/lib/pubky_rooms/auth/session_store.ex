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

  Hydration (a round trip to the user's own homeserver) runs in the calling
  process, never inside this server, so one slow homeserver delays only its
  own user. Two writes racing on a cold entry may both mint a bearer; the
  second one wins and the first simply expires unused on the homeserver.

  A grant the user revoked in Ring (or that expired) leaves a **revoked**
  marker in place of the session: reads report no user, writes fail at once
  without a network call, and `PubkyRoomsWeb.UserAuth` drops the cookie on
  the next request, so the browser is signed out rather than left looking
  signed in with every action failing.

  Connected LiveViews `attach/1` to their session; the entry is dropped 60 s
  after the last one disconnects (the grace covers reloads and navigation).
  Entries that never had a LiveView expire after `session_memory_ttl_ms`. The
  next request from that browser re-seeds them from the cookie. Nothing is
  persisted, and `%Pubky.Auth.Credential{}` redacts its secrets from `inspect`,
  so they cannot leak into logs. The only way to escalate is to compromise the
  running server while a user is connected, and even then only within the
  Rooms namespace, until they revoke in Ring.
  """
  use GenServer

  require Logger

  alias Pubky.Auth.Credential
  alias Pubky.Session

  @table :pubky_sessions
  @sweep_every :timer.minutes(5)
  @disconnect_grace 60_000

  # row layout: {sid, user, export, session | nil | :revoked, last_used}
  @session_pos 4
  @last_used_pos 5

  @type sid :: String.t()
  @type cookie_session :: %{String.t() => String.t()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Caches a freshly minted session and returns its new sid."
  @spec put(Session.t()) :: sid()
  def put(%Session{} = session) do
    sid = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    :ets.insert(@table, {sid, session.user, Session.export(session), session, now()})
    sid
  end

  @doc "The values to store in the browser session cookie for a sid, or nil."
  @spec cookie_session(sid()) :: cookie_session() | nil
  def cookie_session(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, user, export, session, _}] when session != :revoked ->
        %{"sid" => sid, "pubky" => user, "cred" => export}

      _ ->
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

  @doc "Ties the calling LiveView to the session so it is dropped shortly after the last one leaves."
  @spec attach(sid(), pid()) :: :ok
  def attach(sid, pid \\ self()) when is_binary(sid),
    do: GenServer.cast(__MODULE__, {:attach, sid, pid})

  @doc "The session for a sid, hydrating a bearer from the credential if needed."
  @spec lookup(term()) :: {:ok, Session.t()} | :error
  def lookup(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, _, _, %Session{} = session, _}] -> {:ok, session}
      [{^sid, _, export, nil, _}] -> hydrate(sid, export)
      _ -> :error
    end
  end

  def lookup(_), do: :error

  @doc "The user (z32) behind a sid, without hydrating; nil for unknown or revoked sessions. Cheap."
  @spec user_of(term()) :: String.t() | nil
  def user_of(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, user, _, session, _}] when session != :revoked -> user
      _ -> nil
    end
  end

  def user_of(_), do: nil

  @doc "True when the sid is known but its grant was found revoked or expired."
  @spec revoked?(term()) :: boolean()
  def revoked?(sid) when is_binary(sid),
    do: match?([{_, _, _, :revoked, _}], :ets.lookup(@table, sid))

  def revoked?(_), do: false

  @doc """
  Runs `fun.(session)` with a fresh session (see `Pubky.Session.call/3`),
  keeps the refreshed session, and marks the sid revoked when the grant is gone.
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
            revoke(sid, :grant_revoked)
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
    :ets.update_element(@table, sid, {@last_used_pos, now()})
    :ok
  end

  def touch(_), do: :ok

  @doc "Forgets a session and revokes its bearer on the homeserver (best effort)."
  @spec delete(sid()) :: :ok
  def delete(sid) when is_binary(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, _, _, session, _}] ->
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

  defp keep(sid, _old, fresh) do
    # never overwrite a revocation that landed meanwhile
    case :ets.lookup(@table, sid) do
      [{^sid, _, _, :revoked, _}] -> :ok
      _ -> :ets.update_element(@table, sid, {@session_pos, fresh})
    end

    :ok
  end

  defp insert_new(sid, user, export),
    do: :ets.insert_new(@table, {sid, user, export, nil, now()})

  # Mints the bearer in the caller. Revocation leaves a marker so the browser
  # gets signed out; a transport failure leaves the entry cold for a retry.
  defp hydrate(sid, export) do
    with {:ok, credential} <- Credential.import(export),
         {:ok, session} <- Credential.restore(credential) do
      keep(sid, nil, session)
      touch(sid)
      {:ok, session}
    else
      {:error, reason} when reason in [:grant_revoked, :expired, :cnf_mismatch] ->
        revoke(sid, reason)
        :error

      {:error, {:http, status, _}} when status in [401, 403] ->
        revoke(sid, {:http, status})
        :error

      other ->
        Logger.warning(
          "session #{String.slice(sid, 0, 6)}… could not be restored: #{inspect(other)}"
        )

        :error
    end
  end

  defp revoke(sid, reason) do
    Logger.info("session #{String.slice(sid, 0, 6)}… revoked: #{inspect(reason)}")
    :ets.update_element(@table, sid, [{@session_pos, :revoked}, {@last_used_pos, now()}])
  end

  defp now, do: System.monotonic_time(:millisecond)

  # ── server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{pids: %{}, sids: %{}, timers: %{}}}
  end

  @impl true
  def handle_cast({:attach, sid, pid}, state) do
    if Map.has_key?(state.pids, pid) do
      {:noreply, state}
    else
      Process.monitor(pid)
      state = cancel_expiry(state, sid)
      pids = Map.put(state.pids, pid, sid)
      sids = Map.update(state.sids, sid, MapSet.new([pid]), &MapSet.put(&1, pid))
      {:noreply, %{state | pids: pids, sids: sids}}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    ttl = Application.get_env(:pubky_rooms, :session_memory_ttl_ms, 900_000)
    cutoff = now() - ttl

    for {sid, _, _, _, used} <- :ets.tab2list(@table),
        used < cutoff,
        not Map.has_key?(state.sids, sid) do
      :ets.delete(@table, sid)
    end

    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    case Map.pop(state.pids, pid) do
      {nil, _} ->
        {:noreply, state}

      {sid, pids} ->
        remaining = state.sids |> Map.get(sid, MapSet.new()) |> MapSet.delete(pid)
        state = %{state | pids: pids}

        if MapSet.size(remaining) == 0 do
          timer = Process.send_after(self(), {:expire, sid}, @disconnect_grace)
          sids = Map.delete(state.sids, sid)
          {:noreply, %{state | sids: sids, timers: Map.put(state.timers, sid, timer)}}
        else
          {:noreply, %{state | sids: Map.put(state.sids, sid, remaining)}}
        end
    end
  end

  def handle_info({:expire, sid}, state) do
    state = %{state | timers: Map.delete(state.timers, sid)}
    unless Map.has_key?(state.sids, sid), do: :ets.delete(@table, sid)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp cancel_expiry(state, sid) do
    case Map.pop(state.timers, sid) do
      {nil, _} ->
        state

      {timer, timers} ->
        Process.cancel_timer(timer)
        %{state | timers: timers}
    end
  end

  defp signout_async(%Session{} = session) do
    Task.Supervisor.start_child(PubkyRooms.TaskSupervisor, fn -> Session.signout(session) end)
  end

  defp signout_async(_), do: :ok
end

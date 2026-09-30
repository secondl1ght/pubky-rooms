defmodule PubkyRooms.Pubky.Fake do
  @moduledoc """
  An in-memory `PubkyRooms.Pubky` backend for tests.

  Files live in an Agent keyed by `{user, path}`. Writes through a session id
  resolve the user with `PubkyRooms.Auth.SessionStore.user_of/1` and emit a
  `%Pubky.Events.Event{}` synchronously through `PubkyRooms.Events.dispatch/1`,
  exactly as a homeserver event stream would (minus the network). Streams are
  no-ops: every user is implicitly subscribed.

  Because the Agent is a named singleton, tests using it must be `async: false`.
  """
  @behaviour PubkyRooms.Pubky

  use Agent

  alias Pubky.Crypto.Blake3
  alias Pubky.Events.Event
  alias Pubky.Resource
  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Events

  @homeserver "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"

  def start_link(_opts \\ []), do: Agent.start_link(fn -> initial() end, name: __MODULE__)

  defp initial, do: %{files: %{}, cursor: 0, failures: %{}, streams: []}

  @doc "Clears all files and counters (live streams are kept: `Subscriptions` still holds them)."
  def reset, do: Agent.update(__MODULE__, fn s -> %{initial() | streams: s.streams} end)

  @doc "Writes a file directly (no session, no event), e.g. to seed history."
  def seed(user, path, body),
    do: Agent.update(__MODULE__, &put_in(&1, [:files, {user, path}], IO.iodata_to_binary(body)))

  @doc "Removes a file directly (no event), e.g. a deletion nobody streamed."
  def unseed(user, path),
    do: Agent.update(__MODULE__, &%{&1 | files: Map.delete(&1.files, {user, path})})

  @doc "Writes a file as `user` and emits its PUT event (as another client would)."
  def write_as(user, path, body), do: store(user, path, IO.iodata_to_binary(body))

  @doc "Deletes a file as `user` and emits its DEL event."
  def delete_as(user, path), do: remove(user, path)

  @doc "Makes the next write to `path` fail with `reason`."
  def fail_next(path, reason),
    do: Agent.update(__MODULE__, &put_in(&1, [:failures, path], reason))

  @doc "Makes the next file read for `user` fail with `reason` (`{:raise, msg}` crashes the reader, `{:delay, ms}` slows it)."
  def fail_get(user, reason),
    do: Agent.update(__MODULE__, &put_in(&1, [:failures, {:get, user}], reason))

  @doc "Makes the next homeserver resolution for `user` fail with `reason`."
  def fail_resolve(user, reason),
    do: Agent.update(__MODULE__, &put_in(&1, [:failures, {:resolve, user}], reason))

  @doc "Makes the next directory listing for `user` fail with `reason`."
  def fail_list(user, reason),
    do: Agent.update(__MODULE__, &put_in(&1, [:failures, {:list, user}], reason))

  @doc "Makes the next write under `prefix` fail with `reason` (when the exact path is not known)."
  def fail_next_under(prefix, reason),
    do: Agent.update(__MODULE__, &put_in(&1, [:failures, {:prefix, prefix}], reason))

  @doc "All files of a user."
  def files(user) do
    Agent.get(__MODULE__, fn s -> for {{^user, p}, b} <- s.files, into: %{}, do: {p, b} end)
  end

  # ── behaviour ──────────────────────────────────────────────────────────────

  @impl true
  def get(user, path) do
    with :ok <- maybe_fail({:get, user}) do
      case Agent.get(__MODULE__, &Map.fetch(&1.files, {user, path})) do
        {:ok, body} -> {:ok, body}
        :error -> {:error, :not_found}
      end
    end
  end

  @impl true
  def list(user, dir, opts) do
    case maybe_fail({:list, user}) do
      :ok -> do_list(user, dir, opts)
      error -> error
    end
  end

  defp do_list(user, dir, opts) do
    limit = Keyword.get(opts, :limit, 100)
    reverse = Keyword.get(opts, :reverse, false)
    cursor = opts[:cursor] && cursor_path(opts[:cursor])

    paths =
      user
      |> paths_under(dir, Keyword.get(opts, :shallow, false))
      |> Enum.sort(if(reverse, do: :desc, else: :asc))
      |> Enum.filter(&after_cursor?(&1, cursor, reverse))
      |> Enum.take(limit)

    entries = Enum.map(paths, &Resource.new(user, &1))
    next = if length(entries) >= limit, do: entries |> List.last() |> Resource.to_uri(), else: nil

    # like a real homeserver: a directory that holds no files does not exist
    if entries == [] and is_nil(cursor) and not exists_under?(user, dir),
      do: {:error, :not_found},
      else: {:ok, %{entries: entries, next_cursor: next}}
  end

  defp paths_under(user, dir, shallow) do
    Agent.get(__MODULE__, fn s ->
      for {{^user, p}, _} <- s.files, String.starts_with?(p, dir), do: p
    end)
    |> Enum.map(fn p -> if shallow, do: shallow_entry(p, dir), else: p end)
    |> Enum.uniq()
  end

  defp after_cursor?(_path, nil, _reverse), do: true
  defp after_cursor?(path, cursor, true), do: path < cursor
  defp after_cursor?(path, cursor, false), do: path > cursor

  defp exists_under?(user, dir) do
    Agent.get(__MODULE__, fn s ->
      Enum.any?(s.files, fn {{u, p}, _} -> u == user and String.starts_with?(p, dir) end)
    end)
  end

  defp shallow_entry(path, dir) do
    rest = String.replace_prefix(path, dir, "")

    case String.split(rest, "/", parts: 2) do
      [file] -> dir <> file
      [folder, _] -> dir <> folder <> "/"
    end
  end

  defp cursor_path(uri) do
    case Resource.parse(uri) do
      {:ok, %Resource{path: p}} -> p
      :error -> uri
    end
  end

  @impl true
  def put(sid, path, body, _content_type) do
    with {:ok, user} <- session_user(sid),
         :ok <- maybe_fail(path) do
      store(user, path, IO.iodata_to_binary(body))
    end
  end

  @impl true
  def delete(sid, path) do
    with {:ok, user} <- session_user(sid),
         :ok <- maybe_fail(path) do
      remove(user, path)
    end
  end

  @impl true
  def latest_cursor(_user, _path) do
    case Agent.get(__MODULE__, & &1.cursor) do
      0 -> {:ok, nil}
      n -> {:ok, n}
    end
  end

  @impl true
  def homeserver_of(user) do
    with :ok <- maybe_fail({:resolve, user}), do: {:ok, @homeserver}
  end

  @impl true
  def public_url(user, path),
    do: {:ok, "http://fake.homeserver.test" <> path <> "?pubky-host=" <> user}

  @impl true
  def start_stream(opts) do
    {:ok, pid} = Agent.start(fn -> Keyword.get(opts, :users, []) end)
    Agent.update(__MODULE__, &%{&1 | streams: [pid | &1.streams]})
    {:ok, pid}
  end

  @impl true
  def add_users(pid, users), do: Agent.update(pid, &(&1 ++ users))

  @impl true
  def remove_users(pid, users),
    do: Agent.update(pid, fn list -> Enum.reject(list, fn {u, _} -> u in users end) end)

  @impl true
  def stop_stream(pid), do: Agent.stop(pid)

  @impl true
  def stop_all_streams do
    # the app boots before this fake exists (test_helper starts it)
    if Process.whereis(__MODULE__) do
      for pid <- live_streams(), do: Agent.stop(pid)
      Agent.update(__MODULE__, &%{&1 | streams: []})
    end

    :ok
  end

  @doc "Users currently attached to fake streams."
  def stream_users do
    live_streams()
    |> Enum.flat_map(&Agent.get(&1, fn users -> Enum.map(users, fn {u, _} -> u end) end))
  end

  @doc "The pids of the fake streams that are alive."
  def live_streams, do: Agent.get(__MODULE__, & &1.streams) |> Enum.filter(&Process.alive?/1)

  @doc "The live fake stream carrying `user`, or nil."
  def stream_of(user), do: Enum.find(live_streams(), &carries?(&1, user))

  defp carries?(pid, user), do: Agent.get(pid, &List.keymember?(&1, user, 0))

  # ── internals ──────────────────────────────────────────────────────────────

  defp session_user(sid) do
    case SessionStore.user_of(sid) do
      nil -> {:error, :unauthorized}
      user -> {:ok, user}
    end
  end

  defp maybe_fail(path) do
    Agent.get_and_update(__MODULE__, fn s ->
      key =
        Enum.find(Map.keys(s.failures), fn
          ^path -> true
          {:prefix, prefix} when is_binary(path) -> String.starts_with?(path, prefix)
          _ -> false
        end)

      {reason, failures} = Map.pop(s.failures, key)
      {reason, %{s | failures: failures}}
    end)
    |> case do
      nil -> :ok
      # `{:raise, msg}` crashes the caller, `{:delay, ms}` slows it: for the
      # tasks and timeouts around reads
      {:raise, msg} -> raise msg
      {:delay, ms} -> Process.sleep(ms) && :ok
      reason -> {:error, reason}
    end
  end

  defp store(user, path, body) do
    cursor =
      Agent.get_and_update(__MODULE__, fn s ->
        c = s.cursor + 1
        {c, %{s | files: Map.put(s.files, {user, path}, body), cursor: c}}
      end)

    emit(:put, user, path, cursor, Blake3.hash(body))
    :ok
  end

  defp remove(user, path) do
    cursor =
      Agent.get_and_update(__MODULE__, fn s ->
        c = s.cursor + 1
        {c, %{s | files: Map.delete(s.files, {user, path}), cursor: c}}
      end)

    emit(:del, user, path, cursor, nil)
    :ok
  end

  defp emit(type, user, path, cursor, hash) do
    Events.dispatch(%Event{
      type: type,
      user: user,
      path: path,
      uri: "pubky://" <> user <> path,
      cursor: cursor,
      content_hash: hash,
      homeserver: @homeserver
    })
  end
end

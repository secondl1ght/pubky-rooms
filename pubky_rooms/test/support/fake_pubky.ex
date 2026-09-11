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

  @doc "Clears all files and counters."
  def reset, do: Agent.update(__MODULE__, fn _ -> initial() end)

  @doc "Writes a file directly (no session, no event), e.g. to seed history."
  def seed(user, path, body),
    do: Agent.update(__MODULE__, &put_in(&1, [:files, {user, path}], IO.iodata_to_binary(body)))

  @doc "Writes a file as `user` and emits its PUT event (as another client would)."
  def write_as(user, path, body), do: store(user, path, IO.iodata_to_binary(body))

  @doc "Deletes a file as `user` and emits its DEL event."
  def delete_as(user, path), do: remove(user, path)

  @doc "Makes the next write to `path` fail with `reason`."
  def fail_next(path, reason),
    do: Agent.update(__MODULE__, &put_in(&1, [:failures, path], reason))

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
    case Agent.get(__MODULE__, &Map.fetch(&1.files, {user, path})) do
      {:ok, body} -> {:ok, body}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def list(user, dir, opts) do
    limit = Keyword.get(opts, :limit, 100)
    reverse = Keyword.get(opts, :reverse, false)
    shallow = Keyword.get(opts, :shallow, false)
    cursor = opts[:cursor] && cursor_path(opts[:cursor])

    paths =
      Agent.get(__MODULE__, fn s ->
        for {{^user, p}, _} <- s.files, String.starts_with?(p, dir), do: p
      end)
      |> Enum.map(fn p -> if shallow, do: shallow_entry(p, dir), else: p end)
      |> Enum.uniq()
      |> Enum.sort(if(reverse, do: :desc, else: :asc))
      |> Enum.filter(fn p ->
        cond do
          is_nil(cursor) -> true
          reverse -> p < cursor
          true -> p > cursor
        end
      end)
      |> Enum.take(limit)

    entries = Enum.map(paths, &Resource.new(user, &1))
    next = if length(entries) >= limit, do: entries |> List.last() |> Resource.to_uri(), else: nil
    {:ok, %{entries: entries, next_cursor: next}}
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
  def homeserver_of(_user), do: {:ok, @homeserver}

  @impl true
  def start_stream(opts) do
    {:ok, pid} = Agent.start_link(fn -> Keyword.get(opts, :users, []) end)
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

  @doc "Users currently attached to fake streams."
  def stream_users do
    Agent.get(__MODULE__, & &1.streams)
    |> Enum.filter(&Process.alive?/1)
    |> Enum.flat_map(&Agent.get(&1, fn users -> Enum.map(users, fn {u, _} -> u end) end))
  end

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
          {:prefix, prefix} -> String.starts_with?(path, prefix)
          _ -> false
        end)

      {reason, failures} = Map.pop(s.failures, key)
      {reason, %{s | failures: failures}}
    end)
    |> case do
      nil -> :ok
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

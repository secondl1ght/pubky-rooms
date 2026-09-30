defmodule PubkyRooms.Pubky.Live do
  @moduledoc """
  The real `PubkyRooms.Pubky` backend: talks to homeservers through the
  `pubky` library, using `PubkyRooms.Auth.SessionStore` for authenticated writes.
  """
  @behaviour PubkyRooms.Pubky

  alias Pubky.{Events, Resolver, Storage}
  alias Pubky.Events.Stream
  alias PubkyRooms.Auth.SessionStore
  alias PubkyRooms.Pubky, as: Facade

  # Every file Rooms reads is validated at 16 KiB by its reader; the transport
  # cap sits a little above so the reader still gets to say "too large".
  @max_file_bytes 65_536

  @impl true
  def get(user, path) do
    case Storage.get(user, path, max_body: @max_file_bytes) do
      {:ok, %{body: body}} -> {:ok, body}
      other -> Facade.normalize(other)
    end
  end

  @impl true
  def list(user, dir, opts), do: user |> Storage.list(dir, opts) |> Facade.normalize()

  @impl true
  def put(sid, path, body, content_type) do
    sid
    |> SessionStore.call(&Storage.put(&1, path, body, content_type: content_type))
    |> Facade.normalize()
    |> case do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @impl true
  def delete(sid, path) do
    sid
    |> SessionStore.call(&Storage.delete(&1, path))
    |> Facade.normalize()
    |> case do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @impl true
  def latest_cursor(user, path) do
    with {:ok, hs} <- homeserver_of(user) do
      hs |> Events.latest_cursor(user, path) |> Facade.normalize()
    end
  end

  @impl true
  def homeserver_of(user), do: user |> Resolver.homeserver_of() |> Facade.normalize()

  @impl true
  def public_url(user, path), do: user |> Storage.public_url(path) |> Facade.normalize()

  @impl true
  def start_stream(opts), do: Events.start_stream(opts)

  @impl true
  def add_users(pid, users), do: Stream.add_users(pid, users)

  @impl true
  def remove_users(pid, users), do: Stream.remove_users(pid, users)

  @impl true
  def stop_stream(pid), do: Stream.stop(pid)

  @impl true
  def stop_all_streams, do: Events.stop_all_streams()
end

defmodule PubkyRooms.Profiles do
  @moduledoc """
  Display names and avatars for public keys.

  `get/1` is the only call the UI makes: it answers from the ETS cache at
  once and never touches the network. When a key is unknown (or its entry is
  older than `profile_ttl_ms`), the fallback profile is returned and a fetch
  is scheduled through `PubkyRooms.Profiles.Cache`; when the fetch changes
  anything, `{:profile_updated, z32, profile}` is broadcast on the
  `"profiles"` topic (`subscribe/0`) so open LiveViews update in place.

  Sources, in order:

    1. the user's Pubky App profile, `/pub/pubky.app/profile.json`
       (`name`, `image`), so people look the same as on pubky.app
    2. the Rooms nickname, `/pub/pubky-rooms/profile.json` (`name`)
    3. a shortened public key

  Avatars: with `nexus_cdn_url` configured (mainnet) the Pubky App CDN URL
  is used whenever the profile has an image, so avatars match Pubky App
  exactly; otherwise `image` is resolved directly (`https://` as-is,
  `pubky://…/files/<id>` through the file's `src` to a public homeserver
  URL). Without an image the UI renders the generative fallback.
  """

  alias Pubky.Resource
  alias PubkyRooms.Profiles.{Cache, LocalProfile}
  alias PubkyRooms.Pubky
  alias PubkyRooms.Rooms.{Paths, Room}

  @table :pubky_profiles
  @topic "profiles"
  @pubky_app_profile "/pub/pubky.app/profile.json"
  @name_max 50
  @image_url_max 300

  @typedoc "What the UI renders for a user."
  @type profile :: %{
          pubky: String.t(),
          name: String.t(),
          avatar_url: String.t() | nil,
          source: :pubky_app | :local | :fallback
        }

  @doc "The ETS table (owned by `PubkyRooms.Profiles.Cache`)."
  def table, do: @table

  @doc "Subscribes the caller to `{:profile_updated, z32, profile}` messages."
  def subscribe, do: Phoenix.PubSub.subscribe(PubkyRooms.PubSub, @topic)

  @doc "The topic profile updates are broadcast on."
  def topic, do: @topic

  @doc """
  The profile to display for a public key, from the cache. Unknown or stale
  keys return the fallback immediately and are fetched in the background.
  """
  @spec get(String.t()) :: profile()
  def get(z32) when is_binary(z32) do
    case :ets.lookup(@table, z32) do
      [{^z32, profile, fetched_at, ttl}] ->
        if System.monotonic_time(:millisecond) - fetched_at > ttl, do: Cache.fetch(z32)
        profile

      [] ->
        Cache.fetch(z32)
        fallback(z32)
    end
  end

  @doc "Forces a re-fetch (used when the user's own files change)."
  @spec refresh(String.t()) :: :ok
  def refresh(z32) when is_binary(z32), do: Cache.fetch(z32, force: true)

  @doc "The profile shown before anything is known about a key."
  @spec fallback(String.t()) :: profile()
  def fallback(z32), do: %{pubky: z32, name: short_key(z32), avatar_url: nil, source: :fallback}

  @doc "A short, recognizable form of a public key (`ABCD…WXYZ`)."
  @spec short_key(String.t()) :: String.t()
  def short_key(z32) when byte_size(z32) > 8,
    do: String.upcase(String.slice(z32, 0, 4)) <> "…" <> String.upcase(String.slice(z32, -4, 4))

  def short_key(z32), do: z32

  @doc "The Pubky App profile path."
  def pubky_app_profile_path, do: @pubky_app_profile

  # ── fetching (runs in a task started by the cache) ─────────────────────────

  @doc false
  @spec fetch_profile(String.t()) :: {:ok, profile()} | {:error, :unreachable}
  def fetch_profile(z32) do
    with {:ok, app} <- fetch_pubky_app(z32),
         {:ok, local} <- fetch_local(z32) do
      {name, source} =
        cond do
          app[:name] -> {app[:name], :pubky_app}
          local[:name] -> {local[:name], :local}
          true -> {short_key(z32), :fallback}
        end

      {:ok, %{pubky: z32, name: name, avatar_url: avatar_url(z32, app[:image]), source: source}}
    end
  end

  # `{:ok, %{name, image}}` (empty map when the user has no profile); errors
  # other than not-found are reported so the cache can retry soon.
  defp fetch_pubky_app(z32) do
    case Pubky.get(z32, @pubky_app_profile) do
      {:ok, bytes} -> {:ok, parse_pubky_app(bytes)}
      {:error, :not_found} -> {:ok, %{}}
      {:error, :unauthorized} -> {:ok, %{}}
      {:error, _} -> {:error, :unreachable}
    end
  end

  defp parse_pubky_app(bytes) do
    with :ok <- Room.size_ok(bytes),
         {:ok, map} <- Room.decode_json(bytes) do
      %{name: clean_name(map["name"], @name_max), image: clean_url(map["image"])}
    else
      _ -> %{}
    end
  end

  defp fetch_local(z32) do
    case Pubky.get(z32, Paths.profile()) do
      {:ok, bytes} ->
        case LocalProfile.decode(bytes) do
          {:ok, %{name: name}} -> {:ok, %{name: name}}
          {:error, _} -> {:ok, %{}}
        end

      {:error, :not_found} ->
        {:ok, %{}}

      {:error, :unauthorized} ->
        {:ok, %{}}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  defp avatar_url(_z32, nil), do: nil

  defp avatar_url(z32, image) do
    case Application.get_env(:pubky_rooms, :nexus_cdn_url) do
      cdn when is_binary(cdn) and cdn != "" -> String.trim_trailing(cdn, "/") <> "/avatar/" <> z32
      _ -> resolve_image(image)
    end
  end

  # `https://…` is used as-is; `pubky://<user>/pub/pubky.app/files/<id>` points
  # at a file record whose `src` is the blob to show.
  defp resolve_image("http://" <> _ = url), do: url
  defp resolve_image("https://" <> _ = url), do: url

  defp resolve_image("pubky://" <> _ = uri) do
    with {:ok, %Resource{user: user, path: "/pub/pubky.app/files/" <> _ = path}} <-
           Resource.parse(uri),
         {:ok, bytes} <- Pubky.get(user, path),
         :ok <- Room.size_ok(bytes),
         {:ok, %{"src" => src}} <- Room.decode_json(bytes),
         {:ok, %Resource{user: blob_user, path: blob_path}} <- parse_blob(src),
         {:ok, url} <- Pubky.public_url(blob_user, blob_path) do
      url
    else
      _ -> nil
    end
  end

  defp resolve_image(_), do: nil

  defp parse_blob("pubky://" <> _ = src) when byte_size(src) <= @image_url_max,
    do: Resource.parse(src)

  defp parse_blob(_), do: :error

  defp clean_name(name, max) when is_binary(name) do
    name = name |> String.replace(~r/[\p{C}]/u, "") |> String.trim()
    if name == "" or String.length(name) > max, do: nil, else: name
  end

  defp clean_name(_, _), do: nil

  defp clean_url(url) when is_binary(url) and byte_size(url) <= @image_url_max do
    url = String.trim(url)
    if url == "", do: nil, else: url
  end

  defp clean_url(_), do: nil
end

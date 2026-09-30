defmodule Pubky.Storage.Addressing do
  @moduledoc """
  Maps a `{user, path}` onto a homeserver HTTP request.

  Homeservers that advertise the `path-addressed-storage` feature take the
  owner in the URL (`/storage/<user>/pub/...`); older ones take the path as-is
  plus a `pubky-host` header (or `?pubky-host=` query for browsers).

  Paths are encoded segment by segment, so a segment can never smuggle a query
  string, a fragment or an extra `/` into the request; `.` and `..` segments
  are refused outright (they are always a caller bug, never a storage path).
  """

  alias Pubky.PublicKey

  @feature "path-addressed-storage"

  @doc "The feature flag name for path-addressed storage."
  def feature, do: @feature

  @doc "Returns `{url, headers}` for a storage request."
  @spec target(String.t(), [String.t()], PublicKey.z32(), String.t()) ::
          {String.t(), [{String.t(), String.t()}]}
  def target(base_url, features, user, "/" <> _ = path) do
    if @feature in features do
      {base_url <> "/storage/" <> user <> encode_path(path), []}
    else
      {base_url <> encode_path(path), [{"pubky-host", user}]}
    end
  end

  @doc """
  A URL a browser can load without custom headers (uses the `pubky-host`
  query parameter for legacy homeservers).
  """
  @spec public_url(String.t(), [String.t()], PublicKey.z32(), String.t()) :: String.t()
  def public_url(base_url, features, user, "/" <> _ = path) do
    if @feature in features do
      base_url <> "/storage/" <> user <> encode_path(path)
    else
      base_url <> encode_path(path) <> "?pubky-host=" <> user
    end
  end

  @doc "Percent-encodes a storage path one segment at a time."
  @spec encode_path(String.t()) :: String.t()
  def encode_path(path) when is_binary(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &encode_segment/1)
  end

  defp encode_segment(segment) when segment in [".", ".."],
    do: raise(ArgumentError, "storage paths cannot contain #{inspect(segment)} segments")

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end

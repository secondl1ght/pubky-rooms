defmodule Pubky.Storage.Addressing do
  @moduledoc """
  Maps a `{user, path}` onto a homeserver HTTP request.

  Homeservers that advertise the `path-addressed-storage` feature take the
  owner in the URL (`/storage/<user>/pub/...`); older ones take the path as-is
  plus a `pubky-host` header (or `?pubky-host=` query for browsers).
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

  defp encode_path(path), do: URI.encode(path)
end

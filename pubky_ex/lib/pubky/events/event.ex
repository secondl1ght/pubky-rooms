defmodule Pubky.Events.Event do
  @moduledoc """
  A change notification from a homeserver event stream.

  `PUT` events carry the BLAKE3 hash of the new content; `DEL` events do not.
  Cursors are per-user, monotonically increasing ids used to resume a stream.
  """

  alias Pubky.Events.SSE
  alias Pubky.{PublicKey, Resource}

  @type t :: %__MODULE__{
          type: :put | :del,
          user: PublicKey.z32(),
          path: String.t(),
          uri: String.t(),
          cursor: non_neg_integer(),
          content_hash: <<_::256>> | nil,
          homeserver: PublicKey.z32()
        }

  @enforce_keys [:type, :user, :path, :uri, :cursor, :homeserver]
  defstruct [:type, :user, :path, :uri, :cursor, :content_hash, :homeserver]

  @doc "Builds an event from an SSE frame (`event: PUT|DEL` with the standard data lines)."
  @spec from_frame(SSE.frame(), PublicKey.z32()) :: {:ok, t()} | {:error, term()}
  def from_frame(%{event: event, data: data}, homeserver) when event in ["PUT", "DEL"] do
    [uri | fields] = String.split(data, "\n")
    fields = Map.new(fields, &split_field/1)

    with {:ok, %Resource{user: user, path: path}} <- parse_uri(uri),
         {:ok, cursor} <- cursor(fields["cursor"]),
         {:ok, hash} <- content_hash(event, fields["content_hash"]) do
      {:ok,
       %__MODULE__{
         type: if(event == "PUT", do: :put, else: :del),
         user: user,
         path: path,
         uri: uri,
         cursor: cursor,
         content_hash: hash,
         homeserver: homeserver
       }}
    end
  end

  def from_frame(%{event: other}, _homeserver), do: {:error, {:unknown_event, other}}

  defp split_field(line) do
    case String.split(line, ":", parts: 2) do
      [k, v] -> {String.trim(k), String.trim(v)}
      [k] -> {String.trim(k), ""}
    end
  end

  defp parse_uri(uri) do
    case Resource.parse(String.trim(uri)) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, {:invalid_uri, uri}}
    end
  end

  defp cursor(nil), do: {:error, :missing_cursor}

  defp cursor(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:invalid_cursor, str}}
    end
  end

  defp content_hash("DEL", _), do: {:ok, nil}

  defp content_hash("PUT", str) when is_binary(str) do
    case Base.decode64(str) do
      {:ok, <<_::256>> = hash} -> {:ok, hash}
      _ -> {:error, {:invalid_content_hash, str}}
    end
  end

  defp content_hash("PUT", nil), do: {:error, :missing_content_hash}
end

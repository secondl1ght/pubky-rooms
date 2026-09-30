defmodule PubkyRooms.Nexus do
  @moduledoc """
  A thin read-only client for Nexus, Pubky's social indexer, used only for
  discovery: which rooms were tagged from anywhere in the ecosystem, and how
  many people tagged them (ADR 0003). Nexus is optional: with no `nexus_url`
  configured (the testnet), everything works from the local directory alone.

  Requests are anonymous; nothing about the viewer is sent. Tests inject a
  `Req.Test` plug through `config :pubky_rooms, :nexus_req_options`.
  """

  require Logger

  alias PubkyRooms.Tags.Tag

  @type tag :: %{label: String.t(), count: non_neg_integer(), taggers: [String.t()]}
  @type resource :: %{uri: String.t(), tags: [tag()], taggers_count: non_neg_integer()}

  @doc "Whether a Nexus base URL is configured."
  @spec enabled?() :: boolean()
  def enabled?, do: is_binary(base_url())

  @doc "The configured Nexus base URL (e.g. `https://nexus.pubky.app`), or nil."
  @spec base_url() :: String.t() | nil
  def base_url, do: Application.get_env(:pubky_rooms, :nexus_url)

  @doc """
  Resources tagged under the `pubky-rooms` app namespace
  (`GET /v0/stream/resources?app=pubky-rooms`). Options: `sorting`
  (`"timeline"` | `"taggers_count"`), `limit` (≤ 100), `tags` (list, ≤ 5).
  """
  @spec resources(keyword()) :: {:ok, [resource()]} | {:error, term()}
  def resources(opts \\ []) do
    params =
      [
        app: Application.get_env(:pubky_rooms, :app_id, "pubky-rooms"),
        sorting: Keyword.get(opts, :sorting, "timeline"),
        limit: Keyword.get(opts, :limit, 100)
      ] ++ tag_params(opts[:tags])

    with {:ok, body} <- get("/v0/stream/resources", params) do
      {:ok, body |> List.wrap() |> Enum.flat_map(&parse_resource/1)}
    end
  end

  @doc "The tags of one URI from every app (`GET /v0/resource/by-uri?uri=…`)."
  @spec tags_by_uri(String.t()) :: {:ok, [tag()]} | {:error, term()}
  def tags_by_uri(uri) do
    with {:ok, body} <- get("/v0/resource/by-uri", uri: uri) do
      case parse_resource(body) do
        [%{tags: tags}] -> {:ok, tags}
        [] -> {:ok, []}
      end
    end
  end

  defp tag_params(nil), do: []
  defp tag_params(tags), do: [tags: tags |> Enum.take(5) |> Enum.join(",")]

  defp get(path, params) do
    case base_url() do
      nil ->
        {:error, :disabled}

      base ->
        req =
          Req.new(
            [base_url: base, retry: false, receive_timeout: 10_000] ++
              Application.get_env(:pubky_rooms, :nexus_req_options, [])
          )

        case Req.get(req, url: path, params: params) do
          {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
          {:ok, %Req.Response{status: 404}} -> {:ok, []}
          {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
          {:error, reason} -> {:error, {:transport, reason}}
        end
    end
  catch
    kind, reason ->
      Logger.debug("nexus request failed: #{inspect({kind, reason})}")
      {:error, :unreachable}
  end

  # ResourceView: %{"details" => %{"uri" => …}, "tags" => [...], "taggers_count" => n}
  defp parse_resource(%{"details" => %{"uri" => uri}} = view) when is_binary(uri) do
    [
      %{
        uri: uri,
        tags: view |> Map.get("tags", []) |> List.wrap() |> Enum.flat_map(&parse_tag/1),
        taggers_count: int(view["taggers_count"])
      }
    ]
  end

  defp parse_resource(%{"uri" => uri} = view) when is_binary(uri),
    do:
      parse_resource(%{
        "details" => %{"uri" => uri},
        "tags" => view["tags"],
        "taggers_count" => view["taggers_count"]
      })

  defp parse_resource(_), do: []

  # Indexer labels get the same normalisation as tag files read from
  # homeservers; anything Rooms would refuse to write is dropped here too.
  defp parse_tag(%{"label" => label} = tag) when is_binary(label) do
    case Tag.normalize(label) do
      {:ok, label} ->
        taggers = tag |> Map.get("taggers", []) |> List.wrap() |> Enum.filter(&is_binary/1)

        [
          %{
            label: label,
            count: max(int(tag["taggers_count"]), length(taggers)),
            taggers: taggers
          }
        ]

      {:error, _} ->
        []
    end
  end

  defp parse_tag(_), do: []

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0
end

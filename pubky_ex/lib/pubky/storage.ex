defmodule Pubky.Storage do
  @moduledoc """
  Read and write files on Pubky homeservers.

  Public files under `/pub/` are readable by anyone: pass the owner's pubky
  as the target. Writes (and reads of `/priv/`) need a `Pubky.Session` for the
  owner. All functions resolve the homeserver, choose the addressing scheme it
  supports (see `Pubky.Storage.Addressing`) and attach credentials.

  Sessions are immutable; when a bearer token has expired these functions
  return `{:error, {:http, 401, _}}`. Wrap calls in `Pubky.Session.call/3` to
  refresh and retry transparently.
  """

  alias Pubky.{Config, Http, PublicKey, Resolver, Resource, Session}
  alias Pubky.Crypto.Blake3
  alias Pubky.Storage.Addressing

  @type target :: PublicKey.z32() | Session.t()
  @type meta :: %{
          body: binary() | nil,
          content_type: String.t() | nil,
          etag: String.t() | nil,
          content_hash: binary() | nil,
          last_modified: String.t() | nil,
          status: non_neg_integer()
        }
  @type error :: :not_found | :not_modified | :content_hash_mismatch | Http.error() | term()
  @type listing :: %{entries: [Resource.t()], next_cursor: String.t() | nil}

  @default_limit 100

  @doc """
  Fetches a file. Options: `if_none_match:` (an ETag; `{:error, :not_modified}`
  on 304) and `verify: true` (recomputes the BLAKE3 hash and compares it with
  the ETag).
  """
  @spec get(target(), String.t(), keyword(), Config.t()) :: {:ok, meta()} | {:error, error()}
  def get(target, path, opts \\ [], %Config{} = config \\ Config.get()) do
    with {:ok, {url, req_opts}} <- prepare(target, path, opts, config),
         req_opts = maybe_header(req_opts, "if-none-match", opts[:if_none_match]),
         {:ok, resp} <- request(:get, url, req_opts, config) do
      meta = meta(resp)

      if opts[:verify] && meta.content_hash && meta.content_hash != Blake3.hash(meta.body) do
        {:error, :content_hash_mismatch}
      else
        {:ok, meta}
      end
    end
  end

  @doc "Fetches and JSON-decodes a file."
  @spec get_json(target(), String.t(), Config.t()) :: {:ok, term()} | {:error, error()}
  def get_json(target, path, %Config{} = config \\ Config.get()) do
    with {:ok, %{body: body}} <- get(target, path, [], config) do
      case JSON.decode(body) do
        {:ok, json} -> {:ok, json}
        {:error, reason} -> {:error, {:json, reason}}
      end
    end
  end

  @doc "Metadata only (HEAD)."
  @spec head(target(), String.t(), Config.t()) :: {:ok, meta()} | {:error, error()}
  def head(target, path, %Config{} = config \\ Config.get()) do
    with {:ok, {url, req_opts}} <- prepare(target, path, [], config),
         {:ok, resp} <- request(:head, url, req_opts, config) do
      {:ok, meta(resp)}
    end
  end

  @doc "True when the file exists."
  @spec exists?(target(), String.t(), Config.t()) :: boolean()
  def exists?(target, path, %Config{} = config \\ Config.get()),
    do: match?({:ok, _}, head(target, path, config))

  @doc """
  Lists a directory (the path must end with `/`). Options: `limit:` (default
  100, max 1000), `cursor:` (from a previous page), `reverse:`, `shallow:`.
  """
  @spec list(target(), String.t(), keyword(), Config.t()) :: {:ok, listing()} | {:error, error()}
  def list(target, dir, opts \\ [], %Config{} = config \\ Config.get()) do
    unless String.ends_with?(dir, "/"),
      do: raise(ArgumentError, "directory paths must end with /")

    limit = Keyword.get(opts, :limit, @default_limit)

    params =
      [limit: limit, cursor: opts[:cursor], reverse: opts[:reverse], shallow: opts[:shallow]]
      |> Enum.reject(fn {_k, v} -> v in [nil, false] end)

    with {:ok, {url, req_opts}} <- prepare(target, dir, [], config),
         {:ok, %Req.Response{body: body}} <-
           request(:get, url, Keyword.put(req_opts, :params, params), config) do
      entries = parse_listing(body)

      next_cursor =
        if length(entries) >= limit, do: entries |> List.last() |> Resource.to_uri(), else: nil

      {:ok, %{entries: entries, next_cursor: next_cursor}}
    end
  end

  defp parse_listing(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Resource.parse(String.trim(line)) do
        {:ok, r} -> [r]
        :error -> []
      end
    end)
  end

  @doc "Writes a file (creates or replaces). Option: `content_type:` (default `application/octet-stream`)."
  @spec put(Session.t(), String.t(), iodata(), keyword(), Config.t()) :: :ok | {:error, error()}
  def put(%Session{} = session, path, body, opts \\ [], %Config{} = config \\ Config.get()) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    with {:ok, {url, req_opts}} <- prepare(session, path, [], config),
         req_opts =
           req_opts |> maybe_header("content-type", content_type) |> Keyword.put(:body, body),
         {:ok, _} <- request(:put, url, req_opts, config) do
      :ok
    end
  end

  @doc "Writes a JSON file."
  @spec put_json(Session.t(), String.t(), term(), Config.t()) :: :ok | {:error, error()}
  def put_json(%Session{} = session, path, json, %Config{} = config \\ Config.get()),
    do: put(session, path, JSON.encode!(json), [content_type: "application/json"], config)

  @doc "Deletes a file."
  @spec delete(Session.t(), String.t(), Config.t()) :: :ok | {:error, error()}
  def delete(%Session{} = session, path, %Config{} = config \\ Config.get()) do
    with {:ok, {url, req_opts}} <- prepare(session, path, [], config),
         {:ok, _} <- request(:delete, url, req_opts, config) do
      :ok
    end
  end

  @doc "A browser-loadable URL for a user's public file."
  @spec public_url(PublicKey.z32(), String.t(), Config.t()) ::
          {:ok, String.t()} | {:error, term()}
  def public_url(user, path, %Config{} = config \\ Config.get()) do
    with {:ok, {_hs, base_url, features}} <- Resolver.base_url_for_user(user, config) do
      {:ok, Addressing.public_url(base_url, features, user, path)}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp prepare(%Session{} = s, path, _opts, _config) do
    {url, headers} = Addressing.target(s.base_url, s.features, s.user, path)
    {:ok, {url, Http.bearer([headers: headers], s.token)}}
  end

  defp prepare(user, path, _opts, config) when is_binary(user) do
    with {:ok, z32} <- parse_user(user),
         {:ok, {_hs, base_url, features}} <- Resolver.base_url_for_user(z32, config) do
      {url, headers} = Addressing.target(base_url, features, z32, path)
      {:ok, {url, [headers: headers]}}
    end
  end

  defp parse_user(user) do
    case PublicKey.parse(user) do
      {:ok, z32} -> {:ok, z32}
      :error -> {:error, :invalid_public_key}
    end
  end

  defp request(method, url, req_opts, config) do
    case Http.request(method, url, req_opts, config) do
      {:ok, resp} -> {:ok, resp}
      {:error, {:http, 404, _}} -> {:error, :not_found}
      {:error, {:http, 304, _}} -> {:error, :not_modified}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_header(opts, _name, nil), do: opts

  defp maybe_header(opts, name, value),
    do: Keyword.update(opts, :headers, [{name, value}], &[{name, value} | &1])

  defp meta(%Req.Response{status: status, body: body} = resp) do
    etag = header(resp, "etag")

    %{
      body: body,
      content_type: header(resp, "content-type"),
      etag: etag,
      content_hash: etag && decode_etag(etag),
      last_modified: header(resp, "last-modified"),
      status: status
    }
  end

  defp header(resp, name) do
    case Req.Response.get_header(resp, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp decode_etag(etag) do
    case etag |> String.trim("\"") |> Base.decode64() do
      {:ok, <<_::256>> = hash} -> hash
      _ -> nil
    end
  end
end

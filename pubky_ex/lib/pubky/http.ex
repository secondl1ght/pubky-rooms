defmodule Pubky.Http do
  @moduledoc """
  Thin wrapper around `Req` with the defaults every Pubky request shares.

  Responses are returned untouched (`decode_body: false`) because homeserver
  bodies are raw files, plain-text listings, or JSON the caller decodes itself.
  Non-2xx responses become `{:error, {:http, status, body}}`, except `429`,
  which becomes `{:error, {:rate_limited, retry_after_ms | nil}}` (from the
  `Retry-After` header); transport failures become `{:error, {:transport, reason}}`.

  Redirects are never followed: a homeserver answers in place, and following
  one would let a vetted public host send this client anywhere (a 3xx is an
  ordinary `{:error, {:http, status, body}}`).

  Bodies are read in chunks and abandoned once they exceed `:max_body` bytes
  (`{:error, {:body_too_large, limit}}`) or once the whole exchange has taken
  longer than `:deadline` milliseconds (`{:error, {:transport, :deadline}}`),
  so a homeserver that answers with an enormous or endlessly dripping body can
  neither fill this node's memory nor hold a caller forever. The receive
  timeout alone does not cover either case: it restarts with every chunk.
  """

  alias Pubky.Config

  @type error ::
          {:http, non_neg_integer(), binary()}
          | {:rate_limited, non_neg_integer() | nil}
          | {:body_too_large, pos_integer()}
          | {:transport, term()}

  @user_agent "pubky_ex/#{Mix.Project.config()[:version]}"

  @doc """
  Performs a request and returns the response only when the status is 2xx.

  Options are passed to `Req.request/1` after the defaults; `:finch` and
  `:receive_timeout` come from the config unless given. `:max_body` (default
  `config.max_body`) caps the body; `:deadline` (default three times the
  receive timeout) caps the whole exchange. Passing your own `into:` disables
  both, so streaming callers own their limits.
  """
  @spec request(atom(), String.t(), keyword(), Config.t()) ::
          {:ok, Req.Response.t()} | {:error, error()}
  def request(method, url, opts \\ [], %Config{} = config \\ Config.get()) do
    {max_body, opts} = Keyword.pop(opts, :max_body, config.max_body)
    {deadline, opts} = Keyword.pop(opts, :deadline, config.request_timeout * 3)

    req =
      Req.new(
        method: method,
        url: url,
        finch: [name: config.finch],
        receive_timeout: config.request_timeout,
        retry: false,
        redirect: false,
        decode_body: false,
        user_agent: @user_agent,
        into: collector(max_body, deadline)
      )
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %Req.Response{private: %{pubky_abort: reason}}} ->
        {:error, reason}

      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, finish(resp)}

      {:ok, %Req.Response{status: 429} = resp} ->
        {:error, {:rate_limited, retry_after_ms(resp)}}

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, {:http, status, finish(resp).body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc "The `Retry-After` header of a response in milliseconds (delay-seconds form only), or nil."
  @spec retry_after_ms(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after_ms(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [value | _] ->
        case Integer.parse(String.trim(value)) do
          {seconds, ""} when seconds >= 0 -> seconds * 1000
          _ -> nil
        end

      [] ->
        nil
    end
  end

  @doc "Adds an `Authorization: Bearer` header option."
  @spec bearer(keyword(), String.t()) :: keyword()
  def bearer(opts, token), do: add_header(opts, "authorization", "Bearer " <> token)

  @doc "Adds the legacy `pubky-host` header that names the owner of a storage path."
  @spec pubky_host(keyword(), String.t()) :: keyword()
  def pubky_host(opts, z32), do: add_header(opts, "pubky-host", z32)

  defp add_header(opts, name, value) do
    Keyword.update(opts, :headers, [{name, value}], &[{name, value} | &1])
  end

  # A `Req` body collector: accumulates chunks (as a reversed iolist) while the
  # size and the elapsed time stay within bounds, halts otherwise. A declared
  # Content-Length above the cap is refused before any chunk is kept.
  defp collector(max_body, deadline) do
    started = System.monotonic_time(:millisecond)

    fn {:data, chunk}, {req, resp} ->
      size = (resp.private[:pubky_size] || 0) + byte_size(chunk)
      elapsed = System.monotonic_time(:millisecond) - started

      cond do
        elapsed >= deadline ->
          {:halt, {req, Req.Response.put_private(resp, :pubky_abort, {:transport, :deadline})}}

        size > max_body or declared_length(resp) > max_body ->
          {:halt,
           {req, Req.Response.put_private(resp, :pubky_abort, {:body_too_large, max_body})}}

        true ->
          acc = if is_list(resp.body), do: resp.body, else: []
          resp = Req.Response.put_private(%{resp | body: [chunk | acc]}, :pubky_size, size)
          {:cont, {req, resp}}
      end
    end
  end

  defp declared_length(resp) do
    case Req.Response.get_header(resp, "content-length") do
      [value | _] ->
        case Integer.parse(String.trim(value)) do
          {n, ""} -> n
          _ -> 0
        end

      [] ->
        0
    end
  end

  # The collector leaves a reversed iolist; responses without a body keep "".
  defp finish(%Req.Response{body: body} = resp) when is_list(body),
    do: %{resp | body: body |> Enum.reverse() |> IO.iodata_to_binary()}

  defp finish(%Req.Response{body: body} = resp) when is_binary(body), do: resp
  defp finish(%Req.Response{body: body} = resp), do: %{resp | body: inspect(body)}
end

defmodule Pubky.Http do
  @moduledoc """
  Thin wrapper around `Req` with the defaults every Pubky request shares.

  Responses are returned untouched (`decode_body: false`) because homeserver
  bodies are raw files, plain-text listings, or JSON the caller decodes itself.
  Non-2xx responses become `{:error, {:http, status, body}}`, except `429`,
  which becomes `{:error, {:rate_limited, retry_after_ms | nil}}` (from the
  `Retry-After` header); transport failures become `{:error, {:transport, reason}}`.
  """

  alias Pubky.Config

  @type error ::
          {:http, non_neg_integer(), binary()}
          | {:rate_limited, non_neg_integer() | nil}
          | {:transport, term()}

  @user_agent "pubky_ex/#{Mix.Project.config()[:version]}"

  @doc """
  Performs a request and returns the response only when the status is 2xx.

  Options are passed to `Req.request/1` after the defaults; `:finch` and
  `:receive_timeout` come from the config unless given.
  """
  @spec request(atom(), String.t(), keyword(), Config.t()) ::
          {:ok, Req.Response.t()} | {:error, error()}
  def request(method, url, opts \\ [], %Config{} = config \\ Config.get()) do
    req =
      Req.new(
        method: method,
        url: url,
        finch: [name: config.finch],
        receive_timeout: config.request_timeout,
        retry: false,
        decode_body: false,
        user_agent: @user_agent
      )
      |> Req.merge(opts)

    case Req.request(req) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, resp}

      {:ok, %Req.Response{status: 429} = resp} ->
        {:error, {:rate_limited, retry_after_ms(resp)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http, status, to_binary(body)}}

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

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: inspect(body)
end

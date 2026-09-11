defmodule Pubky.Auth.DeepLink do
  @moduledoc """
  `pubkyauth://` deep links, the URLs an app shows as a QR code (or opens on
  mobile) for Pubky Ring to approve.

  Grant sign-in:

      pubkyauth://signin_grant?caps=/pub/app/:rw&relay=https://httprelay.pubky.app/inbox/
        &secret=<base64url 32 bytes>&cid=<client id>&cpk=<client public key>

  Grant sign-up adds `hs=<homeserver>` and optionally `st=<signup token>`.
  Optional `x-source`, `x-success`, `x-error` and `x-cancel` (x-callback-url)
  let the authenticator return to the app.
  """

  alias Pubky.Auth.Capability
  alias Pubky.Crypto.B64
  alias Pubky.PublicKey

  @type params :: %{
          required(:kind) => :signin_grant | :signup_grant,
          required(:caps) => [Capability.t()],
          required(:relay) => String.t(),
          required(:secret) => <<_::256>>,
          required(:client_id) => String.t(),
          required(:client_pk) => PublicKey.z32(),
          optional(:homeserver) => PublicKey.z32(),
          optional(:signup_token) => String.t() | nil,
          optional(:x_callback) => %{optional(String.t()) => String.t()}
        }

  @doc "Builds a grant sign-in deep link."
  @spec signin_grant(map()) :: String.t()
  def signin_grant(params), do: build("signin_grant", params, [])

  @doc "Builds a grant sign-up deep link (`homeserver:` required, `signup_token:` optional)."
  @spec signup_grant(map()) :: String.t()
  def signup_grant(%{homeserver: hs} = params) do
    extra =
      [{"hs", hs}] ++ if params[:signup_token], do: [{"st", params[:signup_token]}], else: []

    build("signup_grant", params, extra)
  end

  @doc "Parses a deep link."
  @spec parse(String.t()) :: {:ok, params()} | {:error, term()}
  def parse("pubkyauth://" <> rest) do
    with {intent, query} <- split_query(rest),
         {:ok, kind} <- kind(intent),
         q = URI.decode_query(query),
         {:ok, caps} <- Capability.split(Map.get(q, "caps", "")),
         {:ok, relay} <- fetch(q, "relay"),
         {:ok, secret_b64} <- fetch(q, "secret"),
         {:ok, secret} <- secret(secret_b64),
         {:ok, client_id} <- fetch(q, "cid"),
         {:ok, cpk} <- fetch(q, "cpk"),
         {:ok, client_pk} <- public_key(cpk),
         {:ok, homeserver} <- optional_homeserver(kind, q) do
      x_callback = q |> Enum.filter(fn {k, _} -> String.starts_with?(k, "x-") end) |> Map.new()

      {:ok,
       %{
         kind: kind,
         caps: caps,
         relay: relay,
         secret: secret,
         client_id: client_id,
         client_pk: client_pk,
         homeserver: homeserver,
         signup_token: Map.get(q, "st"),
         x_callback: x_callback
       }}
    end
  end

  def parse(_), do: {:error, :not_a_pubkyauth_url}

  defp build(intent, params, extra) do
    query =
      URI.encode_query(
        [
          {"caps", Capability.join(params.caps)},
          {"relay", params.relay},
          {"secret", B64.encode(params.secret)},
          {"cid", params.client_id},
          {"cpk", params.client_pk}
        ] ++ extra
      )

    x =
      params
      |> Map.get(:x_callback, %{})
      |> Enum.sort()
      |> Enum.map_join(fn {k, v} -> "&" <> k <> "=" <> URI.encode(v, &URI.char_unreserved?/1) end)

    "pubkyauth://" <> intent <> "?" <> query <> x
  end

  defp split_query(rest) do
    case String.split(rest, "?", parts: 2) do
      [intent, query] -> {String.trim_trailing(intent, "/"), query}
      [intent] -> {String.trim_trailing(intent, "/"), ""}
    end
  end

  defp kind("signin_grant"), do: {:ok, :signin_grant}
  defp kind("signup_grant"), do: {:ok, :signup_grant}
  defp kind(other), do: {:error, {:unsupported_intent, other}}

  defp fetch(q, key) do
    case Map.get(q, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_parameter, key}}
    end
  end

  defp secret(str) do
    case B64.decode(str) do
      {:ok, <<_::256>> = s} -> {:ok, s}
      _ -> {:error, {:invalid_parameter, "secret"}}
    end
  end

  defp public_key(str) do
    case PublicKey.parse(str) do
      {:ok, z32} -> {:ok, z32}
      :error -> {:error, {:invalid_parameter, "cpk"}}
    end
  end

  defp optional_homeserver(:signin_grant, _q), do: {:ok, nil}

  defp optional_homeserver(:signup_grant, q) do
    case PublicKey.parse(Map.get(q, "hs", "")) do
      {:ok, z32} -> {:ok, z32}
      :error -> {:error, {:missing_parameter, "hs"}}
    end
  end
end

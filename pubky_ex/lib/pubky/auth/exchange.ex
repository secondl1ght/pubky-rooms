defmodule Pubky.Auth.Exchange do
  @moduledoc """
  The homeserver side of grant auth: exchanging a grant plus a fresh proof of
  possession for a bearer token (`POST /auth/grant/session`), and creating
  accounts (`POST /auth/grant/signup`).
  """

  alias Pubky.Auth.{Capability, Credential, Grant, Pop}
  alias Pubky.{Config, Http, Keypair, PublicKey, Resolver, Session}

  @doc "Exchanges `grant` (signed for `client`) at `homeserver` for a session."
  @spec session(PublicKey.z32(), Grant.t(), Keypair.t(), Config.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def session(
        homeserver,
        %Grant{} = grant,
        %Keypair{} = client,
        %Config{} = config \\ Config.get()
      ) do
    with {:ok, %{base_url: base_url, features: features}} <-
           Resolver.endpoint_of(homeserver, config),
         {:ok, %Req.Response{body: body}} <-
           post(base_url <> "/auth/grant/session", homeserver, grant, client, config),
         {:ok, %{"token" => token, "session" => info}} when is_binary(token) and is_map(info) <-
           decode(body) do
      {:ok,
       %Session{
         user: grant.iss,
         homeserver: homeserver,
         base_url: base_url,
         features: features,
         token: token,
         token_expires_at: info["token_expires_at"] || 0,
         grant_expires_at: info["grant_expires_at"] || grant.exp,
         grant_id: info["grant_id"] || grant.jti,
         client_id: info["client_id"] || grant.client_id,
         capabilities: capabilities(info["capabilities"], grant.caps),
         created_at: info["created_at"] || System.os_time(:second),
         credential: %Credential{
           grant_jws: grant.jws,
           client_secret: client.secret,
           homeserver: homeserver
         }
       }}
    else
      {:ok, _other} -> {:error, :invalid_session_response}
      {:error, _} = err -> err
    end
  end

  @doc "Creates the user account on `homeserver`. The grant must be a signup grant."
  @spec signup(PublicKey.z32(), Grant.t(), Keypair.t(), String.t() | nil, Config.t()) ::
          :ok | {:error, term()}
  def signup(
        homeserver,
        %Grant{} = grant,
        %Keypair{} = client,
        signup_token \\ nil,
        %Config{} = config \\ Config.get()
      ) do
    query = if signup_token, do: "?signup_token=" <> URI.encode_www_form(signup_token), else: ""

    with {:ok, %{base_url: base_url}} <- Resolver.endpoint_of(homeserver, config),
         {:ok, _} <-
           post(base_url <> "/auth/grant/signup" <> query, homeserver, grant, client, config) do
      :ok
    end
  end

  defp post(url, homeserver, grant, client, config) do
    pop = Pop.sign(client, homeserver, grant.jti)
    body = JSON.encode!(%{grant: grant.jws, pop: pop})

    opts = [
      headers: [{"content-type", "application/json"}, {"pubky-host", grant.iss}],
      body: body
    ]

    Http.request(:post, url, opts, config)
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, json} -> {:ok, json}
      _ -> {:error, :invalid_session_response}
    end
  end

  defp capabilities(list, fallback) when is_list(list) do
    caps = for item <- list, is_binary(item), {:ok, cap} <- [Capability.parse(item)], do: cap
    if caps == [], do: fallback, else: caps
  end

  defp capabilities(_, fallback), do: fallback
end

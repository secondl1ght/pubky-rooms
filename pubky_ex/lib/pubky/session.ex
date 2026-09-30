defmodule Pubky.Session do
  @moduledoc """
  An authenticated homeserver session for one user.

  A session carries a short-lived bearer token (one hour) and the durable
  `Pubky.Auth.Credential` that can mint new ones. The struct is immutable:
  refreshing returns a new session, so keep the latest value (for example in a
  LiveView assign or an ETS row).

      {:ok, session} = Pubky.Auth.LocalSigner.signin(keypair, homeserver, client_id: "my.app")
      {:ok, :ok, session} = Pubky.Session.call(session, &Pubky.Storage.put(&1, "/pub/my.app/hello", "hi"))
  """

  alias Pubky.Auth.{Capability, Credential, Exchange, Grant}
  alias Pubky.{Config, Http, Keypair, PublicKey}

  @type t :: %__MODULE__{
          user: PublicKey.z32(),
          homeserver: PublicKey.z32(),
          base_url: String.t(),
          features: [String.t()],
          token: String.t(),
          token_expires_at: non_neg_integer(),
          grant_expires_at: non_neg_integer(),
          grant_id: String.t(),
          client_id: String.t(),
          capabilities: [Capability.t()],
          created_at: non_neg_integer(),
          credential: Credential.t()
        }

  @derive {Inspect, except: [:token, :credential]}
  @enforce_keys [:user, :homeserver, :base_url, :features, :token, :token_expires_at, :credential]
  defstruct [
    :user,
    :homeserver,
    :base_url,
    :features,
    :token,
    :token_expires_at,
    :grant_expires_at,
    :grant_id,
    :client_id,
    :created_at,
    capabilities: [],
    credential: nil
  ]

  @refresh_slack 300

  @doc "True when the bearer expires within `slack` seconds."
  @spec needs_refresh?(t(), non_neg_integer()) :: boolean()
  def needs_refresh?(%__MODULE__{token_expires_at: exp}, slack \\ @refresh_slack),
    do: exp - slack <= System.os_time(:second)

  @doc "Mints a new bearer from the credential. `{:error, :grant_revoked}` if the homeserver refuses."
  @spec refresh(t(), Config.t()) :: {:ok, t()} | {:error, :grant_revoked | term()}
  def refresh(%__MODULE__{credential: %Credential{} = cred}, %Config{} = config \\ Config.get()) do
    client = Keypair.from_secret(cred.client_secret)

    with {:ok, grant} <- Grant.decode(cred.grant_jws),
         {:ok, session} <- Exchange.session(cred.homeserver, grant, client, config) do
      {:ok, session}
    else
      {:error, {:http, status, _}} when status in [401, 403] -> {:error, :grant_revoked}
      {:error, _} = err -> err
    end
  end

  @doc "Refreshes only when the bearer is about to expire."
  @spec ensure_fresh(t(), Config.t()) :: {:ok, t()} | {:error, term()}
  def ensure_fresh(%__MODULE__{} = session, %Config{} = config \\ Config.get()) do
    if needs_refresh?(session), do: refresh(session, config), else: {:ok, session}
  end

  @doc """
  Runs `fun.(session)` with a fresh bearer, retrying once after a refresh if
  the homeserver answers 401. Returns the result together with the session to
  keep.
  """
  @spec call(t(), (t() -> term()), Config.t()) :: {:ok, term(), t()} | {:error, term(), t()}
  def call(%__MODULE__{} = session, fun, %Config{} = config \\ Config.get())
      when is_function(fun, 1) do
    case ensure_fresh(session, config) do
      {:ok, fresh} -> run(fresh, fun, config)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp run(session, fun, config) do
    case fun.(session) do
      {:error, {:http, 401, _}} -> retry_after_refresh(session, fun, config)
      result -> wrap(result, session)
    end
  end

  defp retry_after_refresh(session, fun, config) do
    case refresh(session, config) do
      {:ok, fresh} -> wrap(fun.(fresh), fresh)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp wrap({:error, reason}, session), do: {:error, reason, session}
  defp wrap(:ok, session), do: {:ok, :ok, session}
  defp wrap({:ok, value}, session), do: {:ok, value, session}
  defp wrap(other, session), do: {:ok, other, session}

  @doc "Session metadata as the homeserver sees it (`GET /auth/grant/session`)."
  @spec info(t(), Config.t()) :: {:ok, map()} | {:error, term()}
  def info(%__MODULE__{} = s, %Config{} = config \\ Config.get()) do
    with {:ok, %{body: body}} <-
           Http.request(:get, s.base_url <> "/auth/grant/session", auth(s), config) do
      JSON.decode(body)
    end
  end

  @doc "Revokes this session's grant on the homeserver (`DELETE /auth/grant/session`)."
  @spec signout(t(), Config.t()) :: :ok | {:error, term()}
  def signout(%__MODULE__{} = s, %Config{} = config \\ Config.get()) do
    with {:ok, _} <- Http.request(:delete, s.base_url <> "/auth/grant/session", auth(s), config),
         do: :ok
  end

  @doc "Lists the user's active grants (requires the root capability)."
  @spec list_grants(t(), Config.t()) :: {:ok, [map()]} | {:error, term()}
  def list_grants(%__MODULE__{} = s, %Config{} = config \\ Config.get()) do
    with {:ok, %{body: body}} <-
           Http.request(:get, s.base_url <> "/auth/grant/sessions", auth(s), config),
         {:ok, list} when is_list(list) <- JSON.decode(body) do
      {:ok, list}
    end
  end

  @doc "Revokes another grant by id (requires the root capability)."
  @spec revoke_grant(t(), String.t(), Config.t()) :: :ok | {:error, term()}
  def revoke_grant(%__MODULE__{} = s, grant_id, %Config{} = config \\ Config.get()) do
    url = s.base_url <> "/auth/grant/session/" <> URI.encode(grant_id, &URI.char_unreserved?/1)
    with {:ok, _} <- Http.request(:delete, url, auth(s), config), do: :ok
  end

  @doc "Exports the durable credential string (see `Pubky.Auth.Credential`)."
  @spec export(t()) :: String.t()
  def export(%__MODULE__{credential: cred}), do: Credential.export(cred)

  @doc "Restores a session from an exported credential string, minting a fresh bearer."
  @spec restore(String.t(), Config.t()) :: {:ok, t()} | {:error, term()}
  def restore(exported, %Config{} = config \\ Config.get()) do
    with {:ok, cred} <- Credential.import(exported), do: Credential.restore(cred, config)
  end

  defp auth(%__MODULE__{token: token, user: user}),
    do: [] |> Http.bearer(token) |> Http.pubky_host(user)
end

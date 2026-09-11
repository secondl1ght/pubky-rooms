defmodule Pubky.Auth.LocalSigner do
  @moduledoc """
  Sign up and sign in with a keypair held **locally**, without Pubky Ring.

  This is the path for tests, development seeding and server-held identities.
  Real users should authorize apps through `Pubky.Auth.GrantFlow` so their
  keys never leave Pubky Ring.
  """

  alias Pubky.Auth.{Capability, Exchange, Grant}
  alias Pubky.{Config, Keypair, PublicKey, Resolver, Session}
  alias Pubky.Pkarr.{Relay, SignedPacket}

  @signup_client_id "pubky.signup"
  @signup_lifetime 300

  @doc """
  Creates the user's account on `homeserver` and publishes their `_pubky`
  record (unless `publish: false`). Pass `signup_token:` for gated homeservers.
  """
  @spec signup(Keypair.t(), PublicKey.z32(), keyword(), Config.t()) :: :ok | {:error, term()}
  def signup(%Keypair{} = user, homeserver, opts \\ [], %Config{} = config \\ Config.get()) do
    client = Keypair.generate()

    grant =
      Grant.sign(user,
        client_id: @signup_client_id,
        caps: [Capability.root()],
        cnf: Keypair.public_z32(client),
        lifetime: @signup_lifetime
      )

    with :ok <- Exchange.signup(homeserver, grant, client, opts[:signup_token], config) do
      if Keyword.get(opts, :publish, true),
        do: publish_homeserver(user, homeserver, config),
        else: :ok
    end
  end

  @doc """
  Signs in with a locally generated grant. Options: `client_id:` (default from
  config), `caps:` (default root), `lifetime:` (seconds), `client:` (PoP keypair).
  `homeserver` may be `nil` to resolve it via PKARR.
  """
  @spec signin(Keypair.t(), PublicKey.z32() | nil, keyword(), Config.t()) ::
          {:ok, Session.t()} | {:error, term()}
  def signin(%Keypair{} = user, homeserver \\ nil, opts \\ [], %Config{} = config \\ Config.get()) do
    client = Keyword.get_lazy(opts, :client, &Keypair.generate/0)

    grant_opts =
      [
        client_id: Keyword.get(opts, :client_id, config.client_id),
        caps: Keyword.get(opts, :caps, [Capability.root()]),
        cnf: Keypair.public_z32(client)
      ] ++
        Keyword.take(opts, [:lifetime])

    with {:ok, hs} <- resolve(homeserver, user, config) do
      Exchange.session(hs, Grant.sign(user, grant_opts), client, config)
    end
  end

  @doc "Publishes (or re-publishes) the user's `_pubky` record pointing at `homeserver`."
  @spec publish_homeserver(Keypair.t(), PublicKey.z32(), Config.t()) :: :ok | {:error, term()}
  def publish_homeserver(%Keypair{} = user, homeserver, %Config{} = config \\ Config.get()) do
    with {:ok, packet} <-
           SignedPacket.build(user, [
             SignedPacket.pubky_record(Keypair.public_z32(user), homeserver)
           ]),
         :ok <- Relay.publish(packet, config) do
      Resolver.invalidate(Keypair.public_z32(user))
    end
  end

  defp resolve(nil, user, config), do: Resolver.homeserver_of(Keypair.public_z32(user), config)
  defp resolve(hs, _user, _config), do: {:ok, hs}
end

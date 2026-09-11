defmodule Pubky.Test.FakeRing do
  @moduledoc """
  Plays Pubky Ring in tests: parses a `pubkyauth://` deep link, signs the
  requested grant with a user keypair, encrypts it with the client secret and
  drops it into the relay channel.
  """

  alias Pubky.Auth.{DeepLink, Grant, RelayChannel}
  alias Pubky.{Config, Http, Keypair}

  @doc "Approves a deep link as `user`. Returns the grant that was sent."
  @spec approve(String.t(), Keypair.t(), Config.t()) :: {:ok, Grant.t()} | {:error, term()}
  def approve(url, %Keypair{} = user, %Config{} = config) do
    with {:ok, params} <- DeepLink.parse(url) do
      grant =
        Grant.sign(user, client_id: params.client_id, caps: params.caps, cnf: params.client_pk)

      body = RelayChannel.seal(grant.jws, params.secret)
      channel = RelayChannel.url(params.relay, params.secret)

      with {:ok, _} <- Http.request(:post, channel, [body: body], config), do: {:ok, grant}
    end
  end
end

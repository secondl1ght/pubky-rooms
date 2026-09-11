defmodule Pubky.Auth.RelayChannel do
  @moduledoc """
  The encrypted rendezvous channel between an app and Pubky Ring on an HTTP relay.

  The channel id is `base64url(blake3(client_secret))`; the relay only ever sees
  that id and an XSalsa20-Poly1305 blob it cannot open. `poll_once/2` long-polls
  `GET {relay}/{id}` (the relay holds the request for ~25 s and answers 408
  when nothing arrived); `ack/2` deletes a delivered message. Legacy `/link`
  relays use the same polling without acknowledgements.
  """

  alias Pubky.{Config, Http}
  alias Pubky.Crypto.{B64, Blake3, Secretbox}

  # relays hold long-polls for 25 s; leave room for slow networks
  @poll_timeout 35_000

  @doc "Derives the channel id from the client secret."
  @spec channel_id(<<_::256>>) :: String.t()
  def channel_id(<<_::256>> = secret), do: B64.encode(Blake3.hash(secret))

  @doc "The channel URL on a relay (`relay` is the inbox base, with or without trailing slash)."
  @spec url(String.t(), <<_::256>>) :: String.t()
  def url(relay_base, secret),
    do: String.trim_trailing(relay_base, "/") <> "/" <> channel_id(secret)

  @doc "True for legacy `/link` relays, which have no ACK endpoint."
  @spec link?(String.t()) :: boolean()
  def link?(relay_base), do: relay_base |> String.trim_trailing("/") |> String.ends_with?("/link")

  @doc "Long-polls the channel once. `:timeout` means nothing arrived yet."
  @spec poll_once(String.t(), Config.t()) :: {:ok, binary()} | :timeout | {:error, term()}
  def poll_once(channel_url, %Config{} = config \\ Config.get()) do
    case Http.request(:get, channel_url, [receive_timeout: @poll_timeout], config) do
      {:ok, %Req.Response{body: body}} when byte_size(body) > 0 -> {:ok, body}
      {:ok, _empty} -> :timeout
      {:error, {:http, 408, _}} -> :timeout
      {:error, {:transport, %{reason: :timeout}}} -> :timeout
      {:error, {:transport, %Mint.TransportError{reason: :timeout}}} -> :timeout
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Acknowledges delivery (best effort; a no-op for legacy relays)."
  @spec ack(String.t(), Config.t()) :: :ok
  def ack(channel_url, %Config{} = config \\ Config.get()) do
    unless link?(Path.dirname(channel_url)), do: Http.request(:delete, channel_url, [], config)
    :ok
  end

  @doc "Decrypts a relay message with the client secret."
  @spec open(binary(), <<_::256>>) :: {:ok, binary()} | :error
  def open(body, secret), do: Secretbox.decrypt(body, secret)

  @doc "Encrypts a message for the channel (what an authenticator does)."
  @spec seal(binary(), <<_::256>>) :: binary()
  def seal(plaintext, secret), do: Secretbox.encrypt(plaintext, secret)
end

defmodule Pubky.Pkarr.Relay do
  @moduledoc """
  Resolve and publish PKARR packets through HTTP relays.

  Relays are tried **sequentially** in the configured order; the first
  verified answer wins. (Racing them would burn the tight per-minute quota of
  `pkarr.pubky.app`.) A `404` means the relay found no record on the DHT and is
  treated as authoritative for that key even if another relay returned an
  invalid payload — an invalid payload is logged as a warning because it
  indicates a broken or hostile relay, never trusted.
  """

  require Logger

  alias Pubky.{Config, Http, PublicKey}
  alias Pubky.Pkarr.SignedPacket

  @receive_timeout 8_000

  @doc "Fetches and verifies the packet published for `z32`."
  @spec resolve(PublicKey.z32(), Config.t()) ::
          {:ok, SignedPacket.t()} | {:error, :not_found | :no_relays | {:relay, term()}}
  def resolve(z32, %Config{} = config \\ Config.get()) do
    Enum.reduce_while(config.pkarr_relays, {:error, :no_relays}, fn relay, _acc ->
      case resolve_at(relay, z32, config) do
        {:ok, packet} -> {:halt, {:ok, packet}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp resolve_at(relay, z32, config) do
    case Http.request(:get, url(relay, z32), [receive_timeout: @receive_timeout], config) do
      {:ok, %Req.Response{body: body}} -> decode(relay, z32, body)
      {:error, {:http, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, {:relay, {relay, reason}}}
    end
  end

  defp decode(relay, z32, body) do
    case SignedPacket.decode_relay_payload(z32, body) do
      {:ok, packet} ->
        {:ok, packet}

      {:error, reason} ->
        Logger.warning("pkarr relay #{relay} returned an invalid payload: #{inspect(reason)}")
        Logger.debug("invalid pkarr payload was for #{String.slice(z32, 0, 8)}…")

        {:error, {:relay, {relay, reason}}}
    end
  end

  @doc "Publishes a signed packet to every configured relay; succeeds if any accepts it."
  @spec publish(SignedPacket.t(), Config.t()) :: :ok | {:error, :no_relays | {:relay, term()}}
  def publish(%SignedPacket{} = packet, %Config{} = config \\ Config.get()) do
    body = SignedPacket.encode_relay_payload(packet)

    config.pkarr_relays
    |> Enum.map(fn relay ->
      Http.request(
        :put,
        url(relay, packet.public_key),
        [body: body, receive_timeout: @receive_timeout],
        config
      )
    end)
    |> Enum.reduce({:error, :no_relays}, fn
      {:ok, _}, _ -> :ok
      _, :ok -> :ok
      {:error, reason}, _ -> {:error, {:relay, reason}}
    end)
  end

  defp url(relay, z32), do: String.trim_trailing(relay, "/") <> "/" <> z32
end

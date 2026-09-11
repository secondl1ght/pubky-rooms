defmodule Pubky.Config do
  @moduledoc """
  Runtime configuration for the Pubky client.

  Every public function in this library accepts an optional `%Pubky.Config{}`
  as its last argument and falls back to `Pubky.Config.get/0`, which reads the
  `:pubky` application environment:

      config :pubky,
        network: :testnet,
        client_id: "rooms.pubky.app"

  `network` selects a preset (`mainnet/1` or `testnet/1`); any other key
  overrides the preset value.

  ## Fields

    * `:network` — `:mainnet`, `:testnet` or `:custom` (informational)
    * `:pkarr_relays` — ordered list of PKARR relay base URLs. Relays are tried
      sequentially; the first answer wins. Never race relays: `pkarr.pubky.app`
      allows only 10 requests per minute.
    * `:http_relay` — HTTP relay inbox base URL used by the auth flow (with trailing `/`)
    * `:plain_http_domains` — ICANN hostnames reached over plain `http://` (local testnets)
    * `:homeserver_overrides` — `%{homeserver_z32 => base_url}` that bypass PKARR resolution
    * `:client_id` — the application's client id shown to the user in Pubky Ring
    * `:finch` / `:stream_finch` — Finch pool names for regular and long-lived (SSE) requests
    * `:request_timeout` — receive timeout for regular requests (ms)
    * `:resolver_ttl` — how long resolved homeservers/endpoints are cached (ms)
    * `:negative_ttl` — how long failed resolutions are cached (ms)
    * `:flow_deadline` — overall deadline for a QR sign-in flow (ms)
  """

  @type t :: %__MODULE__{
          network: :mainnet | :testnet | :custom,
          pkarr_relays: [String.t()],
          http_relay: String.t(),
          plain_http_domains: [String.t()],
          homeserver_overrides: %{optional(String.t()) => String.t()},
          client_id: String.t(),
          finch: atom(),
          stream_finch: atom(),
          request_timeout: pos_integer(),
          resolver_ttl: pos_integer(),
          negative_ttl: pos_integer(),
          flow_deadline: pos_integer()
        }

  defstruct network: :mainnet,
            pkarr_relays: ["https://pkarr.pubky.org", "https://pkarr.pubky.app"],
            http_relay: "https://httprelay.pubky.app/inbox/",
            plain_http_domains: ["localhost", "127.0.0.1"],
            homeserver_overrides: %{},
            client_id: "pubky-ex.example",
            finch: Pubky.Finch,
            stream_finch: Pubky.Finch.Streams,
            request_timeout: 10_000,
            resolver_ttl: 300_000,
            negative_ttl: 30_000,
            flow_deadline: 600_000

  @testnet_homeserver "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"

  @doc "The fixed public key of the pubky-docker / pubky-testnet homeserver."
  @spec testnet_homeserver() :: String.t()
  def testnet_homeserver, do: @testnet_homeserver

  @doc "Mainnet preset (public relays, DHT-published homeservers)."
  @spec mainnet(keyword() | map()) :: t()
  def mainnet(overrides \\ []), do: struct!(%__MODULE__{network: :mainnet}, overrides)

  @doc """
  Local testnet preset for a `pubky-docker` / `pubky-testnet` stack on `localhost`.

  The testnet homeserver's PKARR record already advertises `localhost` with a
  plain-HTTP port, so the override is only a shortcut that avoids the relay round trip.
  """
  @spec testnet(keyword() | map()) :: t()
  def testnet(overrides \\ []) do
    struct!(
      %__MODULE__{
        network: :testnet,
        pkarr_relays: ["http://localhost:15411"],
        http_relay: "http://localhost:15412/inbox/",
        homeserver_overrides: %{@testnet_homeserver => "http://localhost:6286"}
      },
      overrides
    )
  end

  @doc """
  Builds the configuration from the `:pubky` application environment.

  `config :pubky, network: :testnet` picks the preset; every other configured
  key overrides it. Unknown keys raise, so typos are caught at boot.
  """
  @spec get() :: t()
  def get do
    env = Application.get_all_env(:pubky) |> Keyword.drop([:included_applications])
    {network, overrides} = Keyword.pop(env, :network, :mainnet)

    case network do
      :testnet -> testnet(overrides)
      :mainnet -> mainnet(overrides)
      :custom -> struct!(%__MODULE__{network: :custom}, overrides)
      other -> raise ArgumentError, "unknown :pubky network #{inspect(other)}"
    end
  end
end

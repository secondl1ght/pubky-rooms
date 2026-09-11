defmodule Pubky.Pkarr.Endpoint do
  @moduledoc """
  Picks the HTTP endpoint of a homeserver from its PKARR packet.

  A homeserver publishes `HTTPS`/`SVCB` records at its apex name. Typically:

      <hs> HTTPS 1 . port=6287 ipv4hint=…          # direct PubkyTLS endpoint (raw-public-key TLS)
      <hs> HTTPS 10 homeserver.example.com          # ICANN endpoint behind ordinary TLS

  Erlang's `:ssl` cannot speak raw-public-key TLS, so this client always uses
  the ICANN endpoint: the lowest-priority record whose target is a real domain.
  Local testnets advertise `localhost` together with the Pubky-reserved
  SvcParam `65280` carrying a plain-HTTP port.
  """

  alias Pubky.{Config, PublicKey}
  alias Pubky.Pkarr.{Dns, SignedPacket}

  @type endpoint :: %{
          priority: non_neg_integer(),
          target: String.t(),
          port: non_neg_integer() | nil,
          http_port: non_neg_integer() | nil,
          ipv4hints: [:inet.ip4_address()]
        }

  @doc "All service endpoints advertised at the packet's apex, HTTPS records first."
  @spec from_packet(SignedPacket.t()) :: [endpoint()]
  def from_packet(%SignedPacket{} = sp) do
    apex = SignedPacket.resource_records(sp, "@")

    https = for %{rdata: {:https, svc}} <- apex, do: to_endpoint(svc)
    svcb = for %{rdata: {:svcb, svc}} <- apex, do: to_endpoint(svc)
    https ++ svcb
  end

  @doc """
  The base URL of the ICANN endpoint, e.g. `"https://homeserver.pubky.app"` or
  `"http://localhost:6286"`. Returns `{:error, :no_icann_endpoint}` when the
  homeserver only advertises a direct PubkyTLS endpoint.
  """
  @spec icann_base_url([endpoint()], Config.t()) ::
          {:ok, String.t()} | {:error, :no_icann_endpoint}
  def icann_base_url(endpoints, %Config{} = config \\ Config.get()) do
    endpoints
    |> Enum.filter(&domain_target?/1)
    |> Enum.sort_by(& &1.priority)
    |> case do
      [] -> {:error, :no_icann_endpoint}
      [ep | _] -> {:ok, base_url(ep, config)}
    end
  end

  defp to_endpoint(%{priority: priority, target: target, params: params}) do
    %{
      priority: priority,
      target: target,
      port: Dns.svcparam_u16(params, Dns.svcparam_port()),
      http_port: Dns.svcparam_u16(params, Dns.svcparam_http_port()),
      ipv4hints: Dns.ipv4hints(params)
    }
  end

  defp domain_target?(%{target: ""}), do: false
  defp domain_target?(%{target: target}), do: not PublicKey.valid?(target)

  defp base_url(%{target: host, http_port: http_port, port: port}, config) do
    plain? = http_port != nil or host in config.plain_http_domains

    cond do
      plain? -> with_port("http://" <> host, http_port || port, 80)
      true -> with_port("https://" <> host, port, 443)
    end
  end

  defp with_port(base, nil, _default), do: base
  defp with_port(base, port, default) when port == default, do: base
  defp with_port(base, port, _default), do: "#{base}:#{port}"
end

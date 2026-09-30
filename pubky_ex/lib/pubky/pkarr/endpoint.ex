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

  Targets are chosen by whoever signs the packet, so on mainnet
  (`allow_private_hosts: false`) only public hostnames are accepted: loopback,
  private and link-local addresses (in any spelling the resolver would accept,
  `127.1` included) and reserved names such as `localhost` or `*.internal` are
  skipped, and a key that advertises nothing else resolves to
  `{:error, :no_icann_endpoint}`. The name that survives is then resolved by
  `Pubky.Resolver` and every address it yields must be public too
  (`resolves_public?/1`), so a public name with a private A record is refused
  as well. The plain-HTTP SvcParam `65280` is honoured only for
  `plain_http_domains` or when private hosts are allowed. Otherwise any user
  could point this client at services on the node's own network.
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

  @reserved_suffixes [".localhost", ".local", ".internal", ".home.arpa", ".onion", ".test"]
  @label ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

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
  homeserver only advertises a direct PubkyTLS endpoint or (on mainnet) only
  private hosts.
  """
  @spec icann_base_url([endpoint()], Config.t()) ::
          {:ok, String.t()} | {:error, :no_icann_endpoint}
  def icann_base_url(endpoints, %Config{} = config \\ Config.get()) do
    endpoints
    |> Enum.filter(&(domain_target?(&1) and allowed_target?(&1.target, config)))
    |> Enum.sort_by(& &1.priority)
    |> case do
      [] -> {:error, :no_icann_endpoint}
      [ep | _] -> {:ok, base_url(ep, config)}
    end
  end

  @doc """
  Whether a target host may be contacted under `config`: any host when
  `allow_private_hosts` is set, otherwise only a public hostname (`public_host?/1`).
  """
  @spec allowed_target?(String.t(), Config.t()) :: boolean()
  def allowed_target?(host, %Config{allow_private_hosts: true}), do: host != ""
  def allowed_target?(host, %Config{}), do: public_host?(host)

  @doc """
  True for a well-formed public hostname: RFC 1123 labels with at least one
  dot and an alphabetic top-level label (so shortened, hex or octal address
  spellings such as `127.1` or `0x7f.1` are not names), no reserved suffix,
  and — for IP literals in any form the resolver accepts — no loopback,
  private, link-local, multicast or otherwise non-routable address. Purely
  syntactic: see `resolves_public?/1` for what the name points at.
  """
  @spec public_host?(String.t()) :: boolean()
  def public_host?(host) when is_binary(host) do
    host = host |> String.trim_trailing(".") |> String.downcase()

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> public_ip?(ip)
      {:error, _} -> public_name?(host)
    end
  end

  @doc """
  True unless the name resolves (A or AAAA) to a non-public address. A name
  that does not resolve at all passes: the connection fails on its own.
  """
  @spec resolves_public?(String.t()) :: boolean()
  def resolves_public?(host) when is_binary(host) do
    name = String.to_charlist(host)

    [:inet, :inet6]
    |> Enum.flat_map(fn family ->
      case :inet.getaddrs(name, family) do
        {:ok, addresses} -> addresses
        {:error, _} -> []
      end
    end)
    |> Enum.all?(&public_ip?/1)
  end

  @doc "Whether the resolver may connect to `host` under `config`: allowed outright, or public by name and by address."
  @spec vetted_host?(String.t(), Config.t()) :: boolean()
  def vetted_host?(_host, %Config{allow_private_hosts: true}), do: true
  def vetted_host?(host, %Config{}), do: public_host?(host) and resolves_public?(host)

  defp public_name?(host) do
    labels = String.split(host, ".")

    byte_size(host) <= 253 and length(labels) >= 2 and
      Enum.all?(labels, &Regex.match?(@label, &1)) and
      Regex.match?(~r/^[a-z]/, List.last(labels)) and
      not Enum.any?(@reserved_suffixes, &String.ends_with?(host, &1))
  end

  defp public_ip?({a, _, _, _}) when a in [0, 10, 127], do: false
  defp public_ip?({100, b, _, _}) when b in 64..127, do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b in 16..31, do: false
  defp public_ip?({192, 0, 0, _}), do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({198, b, _, _}) when b in 18..19, do: false
  defp public_ip?({a, _, _, _}) when a >= 224, do: false
  defp public_ip?({_, _, _, _}), do: true
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: public_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp public_ip?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}),
    do: public_ip?({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false
  defp public_ip?({_, _, _, _, _, _, _, _}), do: true

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

  # Plain HTTP only where the operator allows it (local testnets); a mainnet
  # packet cannot downgrade the client to cleartext toward an arbitrary host.
  defp base_url(%{target: host, http_port: http_port, port: port}, config) do
    plain? =
      host in config.plain_http_domains or (http_port != nil and config.allow_private_hosts)

    if plain? do
      with_port("http://" <> host, http_port || port, 80)
    else
      with_port("https://" <> host, port, 443)
    end
  end

  defp with_port(base, nil, _default), do: base
  defp with_port(base, port, default) when port == default, do: base
  defp with_port(base, port, _default), do: "#{base}:#{port}"
end

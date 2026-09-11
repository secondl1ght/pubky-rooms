defmodule Pubky.Pkarr.SignedPacket do
  @moduledoc """
  A PKARR signed packet: an Ed25519-signed DNS packet published for a public key.

  Relay payload layout (see `pkarr/design/relays.md`):

      signature (64 bytes) || timestamp_us (8 bytes, big-endian) || dns_packet (≤ 1000 bytes)

  The signature covers the BEP44 mutable-item encoding of the packet,
  `"3:seqi<timestamp>e1:v<len>:" <> packet`, and is verified against the
  public key the payload was fetched for.
  """

  alias Pubky.Crypto.Ed25519
  alias Pubky.{Keypair, PublicKey}
  alias Pubky.Pkarr.Dns
  alias Pubky.Pkarr.Dns.RR

  @type t :: %__MODULE__{
          public_key: PublicKey.z32(),
          timestamp_us: non_neg_integer(),
          packet: binary(),
          records: [RR.t()],
          signature: binary()
        }

  @enforce_keys [:public_key, :timestamp_us, :packet, :records, :signature]
  defstruct [:public_key, :timestamp_us, :packet, :records, :signature]

  @max_packet 1000

  @doc "Decodes and verifies a relay payload fetched for `z32`."
  @spec decode_relay_payload(PublicKey.z32(), binary()) ::
          {:ok, t()}
          | {:error, :too_short | :too_large | :bad_public_key | :bad_signature | {:dns, term()}}
  def decode_relay_payload(z32, <<sig::binary-64, ts::unsigned-big-64, packet::binary>>) do
    with :ok <- check_size(packet),
         {:ok, pk} <- pk_bytes(z32),
         true <- Ed25519.verify(pk, signable(ts, packet), sig) || {:error, :bad_signature},
         {:ok, %Dns.Packet{} = dns} <- dns_decode(packet) do
      {:ok,
       %__MODULE__{
         public_key: z32,
         timestamp_us: ts,
         packet: packet,
         records: dns.answers ++ dns.authorities ++ dns.additionals,
         signature: sig
       }}
    end
  end

  def decode_relay_payload(_z32, _body), do: {:error, :too_short}

  @doc "Encodes a signed packet as a relay payload."
  @spec encode_relay_payload(t()) :: binary()
  def encode_relay_payload(%__MODULE__{signature: sig, timestamp_us: ts, packet: packet}),
    do: sig <> <<ts::unsigned-big-64>> <> packet

  @doc "The bytes the signature covers (BEP44 `seq`/`v` bencoding)."
  @spec signable(non_neg_integer(), binary()) :: binary()
  def signable(ts, packet), do: "3:seqi#{ts}e1:v#{byte_size(packet)}:" <> packet

  @doc "Builds and signs a packet with the given answer records."
  @spec build(Keypair.t(), [RR.t()], non_neg_integer()) :: {:ok, t()} | {:error, :too_large}
  def build(%Keypair{} = keypair, records, timestamp_us \\ System.os_time(:microsecond)) do
    packet = Dns.encode(%Dns.Packet{answers: records})

    with :ok <- check_size(packet) do
      {:ok,
       %__MODULE__{
         public_key: Keypair.public_z32(keypair),
         timestamp_us: timestamp_us,
         packet: packet,
         records: records,
         signature: Keypair.sign(keypair, signable(timestamp_us, packet))
       }}
    end
  end

  @doc """
  Records whose name matches `name`, where `name` may be relative to the key:
  `"_pubky"` means `"_pubky.<z32>"`, and `"@"`, `"."` or `""` mean the apex `"<z32>"`.
  """
  @spec resource_records(t(), String.t()) :: [RR.t()]
  def resource_records(%__MODULE__{public_key: z32, records: records}, name) do
    full = qualify(name, z32)
    Enum.filter(records, &(&1.name == full))
  end

  @doc "The `_pubky` HTTPS record pointing a user key at a homeserver key (TTL 3600)."
  @spec pubky_record(PublicKey.z32(), PublicKey.z32(), non_neg_integer()) :: RR.t()
  def pubky_record(user_z32, homeserver_z32, ttl \\ 3600) do
    %RR{
      name: "_pubky." <> user_z32,
      type: Dns.type(:https),
      class: 1,
      ttl: ttl,
      rdata: {:https, %{priority: 0, target: homeserver_z32, params: %{}}}
    }
  end

  defp qualify(name, z32) do
    case String.trim_trailing(String.downcase(name), ".") do
      n when n in ["", "@"] -> z32
      n -> if String.ends_with?(n, z32), do: n, else: n <> "." <> z32
    end
  end

  defp check_size(packet) when byte_size(packet) > @max_packet, do: {:error, :too_large}
  defp check_size(_), do: :ok

  defp pk_bytes(z32) do
    case PublicKey.to_bytes(z32) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :bad_public_key}
    end
  end

  defp dns_decode(packet) do
    case Dns.decode(packet) do
      {:ok, dns} -> {:ok, dns}
      {:error, reason} -> {:error, {:dns, reason}}
    end
  end
end

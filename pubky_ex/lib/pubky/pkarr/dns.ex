defmodule Pubky.Pkarr.Dns do
  @moduledoc """
  Minimal DNS wire-format codec (RFC 1035) for PKARR packets.

  PKARR records are ordinary DNS answer packets, at most 1000 bytes. This
  module decodes any packet (names with compression pointers, all sections)
  and understands the record types Pubky uses: `A`, `AAAA`, `CNAME`, `TXT`,
  `SVCB` (64) and `HTTPS` (65) with their SvcParams. Unknown types are kept as
  `{:raw, binary}`. Decoding never raises on malformed input.

  The encoder writes answer-only packets with uncompressed names, which is all
  Pubky clients ever publish (the user's `_pubky` record).
  """

  defmodule RR do
    @moduledoc "A resource record. `name` is lower-case without a trailing dot; the root name is `\"\"`."
    @type rdata ::
            {:a, :inet.ip4_address()}
            | {:aaaa, :inet.ip6_address()}
            | {:cname, String.t()}
            | {:txt, [binary()]}
            | {:https | :svcb,
               %{
                 priority: non_neg_integer(),
                 target: String.t(),
                 params: %{non_neg_integer() => binary()}
               }}
            | {:raw, binary()}
    @type t :: %__MODULE__{
            name: String.t(),
            type: non_neg_integer(),
            class: non_neg_integer(),
            ttl: non_neg_integer(),
            rdata: rdata()
          }
    defstruct name: "", type: 0, class: 1, ttl: 0, rdata: {:raw, <<>>}
  end

  defmodule Packet do
    @moduledoc "A decoded DNS packet."
    @type t :: %__MODULE__{
            id: non_neg_integer(),
            flags: non_neg_integer(),
            questions: [%{name: String.t(), type: non_neg_integer(), class: non_neg_integer()}],
            answers: [RR.t()],
            authorities: [RR.t()],
            additionals: [RR.t()]
          }
    defstruct id: 0, flags: 0x8000, questions: [], answers: [], authorities: [], additionals: []
  end

  @type_a 1
  @type_cname 5
  @type_txt 16
  @type_aaaa 28
  @type_svcb 64
  @type_https 65

  @doc "Numeric record type for a symbolic name."
  @spec type(:a | :cname | :txt | :aaaa | :svcb | :https) :: non_neg_integer()
  def type(:a), do: @type_a
  def type(:cname), do: @type_cname
  def type(:txt), do: @type_txt
  def type(:aaaa), do: @type_aaaa
  def type(:svcb), do: @type_svcb
  def type(:https), do: @type_https

  @svcparam_port 3
  @svcparam_ipv4hint 4
  @svcparam_ipv6hint 6
  # Pubky-reserved private-use key advertising a plain-HTTP port (used on local testnets).
  @svcparam_http_port 65_280

  @doc "SvcParam key for the service port."
  def svcparam_port, do: @svcparam_port
  @doc "SvcParam key for IPv4 hints."
  def svcparam_ipv4hint, do: @svcparam_ipv4hint
  @doc "SvcParam key for IPv6 hints."
  def svcparam_ipv6hint, do: @svcparam_ipv6hint
  @doc "Pubky's private-use SvcParam key carrying a plain-HTTP port."
  def svcparam_http_port, do: @svcparam_http_port

  @max_jumps 16

  # ── Decoding ───────────────────────────────────────────────────────────────

  @doc "Decodes a DNS packet. Returns `{:error, reason}` instead of raising on malformed input."
  @spec decode(binary()) :: {:ok, Packet.t()} | {:error, term()}
  def decode(<<id::16, flags::16, qd::16, an::16, ns::16, ar::16, _::binary>> = packet) do
    with {:ok, questions, off} <- decode_questions(packet, 12, qd, []),
         {:ok, answers, off} <- decode_rrs(packet, off, an, []),
         {:ok, authorities, off} <- decode_rrs(packet, off, ns, []),
         {:ok, additionals, _off} <- decode_rrs(packet, off, ar, []) do
      {:ok,
       %Packet{
         id: id,
         flags: flags,
         questions: questions,
         answers: answers,
         authorities: authorities,
         additionals: additionals
       }}
    end
  end

  def decode(_), do: {:error, :truncated_header}

  defp decode_questions(_packet, off, 0, acc), do: {:ok, Enum.reverse(acc), off}

  defp decode_questions(packet, off, n, acc) do
    with {:ok, name, off} <- decode_name(packet, off),
         <<_::binary-size(off), type::16, class::16, _::binary>> <- packet do
      decode_questions(packet, off + 4, n - 1, [%{name: name, type: type, class: class} | acc])
    else
      {:error, _} = err -> err
      _ -> {:error, {:truncated, off}}
    end
  end

  defp decode_rrs(_packet, off, 0, acc), do: {:ok, Enum.reverse(acc), off}

  defp decode_rrs(packet, off, n, acc) do
    with {:ok, name, off} <- decode_name(packet, off),
         <<_::binary-size(off), type::16, class::16, ttl::32, rdlen::16,
           rdata::binary-size(rdlen),
           _::binary>> <-
           packet do
      rdata_off = off + 10

      rr = %RR{
        name: name,
        type: type,
        class: class,
        ttl: ttl,
        rdata: decode_rdata(type, rdata, packet, rdata_off)
      }

      decode_rrs(packet, rdata_off + rdlen, n - 1, [rr | acc])
    else
      {:error, _} = err -> err
      _ -> {:error, {:truncated, off}}
    end
  end

  defp decode_rdata(@type_a, <<a, b, c, d>>, _packet, _off), do: {:a, {a, b, c, d}}

  defp decode_rdata(
         @type_aaaa,
         <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>,
         _packet,
         _off
       ),
       do: {:aaaa, {a, b, c, d, e, f, g, h}}

  defp decode_rdata(@type_cname, _rdata, packet, off) do
    case decode_name(packet, off) do
      {:ok, name, _} -> {:cname, name}
      _ -> {:raw, binary_part(packet, off, min(byte_size(packet) - off, 255))}
    end
  end

  defp decode_rdata(@type_txt, rdata, _packet, _off), do: {:txt, decode_txt(rdata, [])}

  defp decode_rdata(type, <<priority::16, _::binary>> = rdata, packet, off)
       when type in [@type_svcb, @type_https] do
    case decode_name(packet, off + 2) do
      {:ok, target, next} ->
        params_bin = binary_part(rdata, next - off, byte_size(rdata) - (next - off))
        params = decode_svcparams(params_bin, %{})

        {if(type == @type_https, do: :https, else: :svcb),
         %{priority: priority, target: target, params: params}}

      _ ->
        {:raw, rdata}
    end
  end

  defp decode_rdata(_type, rdata, _packet, _off), do: {:raw, rdata}

  defp decode_txt(<<len, str::binary-size(len), rest::binary>>, acc),
    do: decode_txt(rest, [str | acc])

  defp decode_txt(_, acc), do: Enum.reverse(acc)

  defp decode_svcparams(<<key::16, len::16, value::binary-size(len), rest::binary>>, acc),
    do: decode_svcparams(rest, Map.put(acc, key, value))

  defp decode_svcparams(_, acc), do: acc

  @doc """
  Decodes a (possibly compressed) domain name starting at `offset`.

  Returns the lower-cased dotted name and the offset just past the name in the
  original stream (pointers do not advance it). Loops are bounded by a jump limit.
  """
  @spec decode_name(binary(), non_neg_integer()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def decode_name(packet, offset), do: decode_name(packet, offset, [], nil, 0)

  defp decode_name(_packet, _off, _labels, _ret, jumps) when jumps > @max_jumps,
    do: {:error, :pointer_loop}

  defp decode_name(packet, off, labels, ret, jumps) do
    case packet do
      <<_::binary-size(off), 0, _::binary>> ->
        {:ok, labels |> Enum.reverse() |> Enum.join("."), ret || off + 1}

      <<_::binary-size(off), 0b11::2, ptr::14, _::binary>> ->
        decode_name(packet, ptr, labels, ret || off + 2, jumps + 1)

      <<_::binary-size(off), len::8, label::binary-size(len), _::binary>> when len < 64 ->
        decode_name(packet, off + 1 + len, [String.downcase(label) | labels], ret, jumps)

      _ ->
        {:error, {:truncated, off}}
    end
  end

  # ── Encoding ───────────────────────────────────────────────────────────────

  @doc "Encodes an answer-only packet (flags `0x8000`, no compression)."
  @spec encode(Packet.t()) :: binary()
  def encode(%Packet{answers: answers} = p) do
    header = <<p.id::16, p.flags::16, 0::16, length(answers)::16, 0::16, 0::16>>
    Enum.reduce(answers, header, fn rr, acc -> acc <> encode_rr(rr) end)
  end

  defp encode_rr(%RR{} = rr) do
    rdata = encode_rdata(rr.rdata)

    encode_name(rr.name) <>
      <<rr.type::16, rr.class::16, rr.ttl::32, byte_size(rdata)::16>> <> rdata
  end

  defp encode_rdata({:a, {a, b, c, d}}), do: <<a, b, c, d>>

  defp encode_rdata({:aaaa, {a, b, c, d, e, f, g, h}}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  defp encode_rdata({:cname, name}), do: encode_name(name)

  defp encode_rdata({:txt, strings}),
    do: Enum.map_join(strings, fn s -> <<byte_size(s)>> <> s end)

  defp encode_rdata({kind, %{priority: priority, target: target} = svc})
       when kind in [:https, :svcb] do
    params =
      svc
      |> Map.get(:params, %{})
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join(fn {k, v} -> <<k::16, byte_size(v)::16>> <> v end)

    <<priority::16>> <> encode_name(target) <> params
  end

  defp encode_rdata({:raw, bin}), do: bin

  @doc "Encodes a dotted name (no compression). The root name encodes to a single zero byte."
  @spec encode_name(String.t()) :: binary()
  def encode_name(name) when name in ["", "."], do: <<0>>

  def encode_name(name) do
    name
    |> String.trim_trailing(".")
    |> String.split(".")
    |> Enum.map_join(fn label -> <<byte_size(label)>> <> label end)
    |> Kernel.<>(<<0>>)
  end

  @doc "Extracts the port from an SvcParams map, if present."
  @spec svcparam_u16(%{non_neg_integer() => binary()}, non_neg_integer()) ::
          non_neg_integer() | nil
  def svcparam_u16(params, key) do
    case Map.get(params, key) do
      <<v::16>> -> v
      _ -> nil
    end
  end

  @doc "Extracts IPv4 hints from an SvcParams map."
  @spec ipv4hints(%{non_neg_integer() => binary()}) :: [:inet.ip4_address()]
  def ipv4hints(params) do
    case Map.get(params, @svcparam_ipv4hint) do
      nil -> []
      bin -> for <<a, b, c, d <- bin>>, do: {a, b, c, d}
    end
  end
end

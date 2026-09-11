defmodule Pubky.Auth.GrantFlow do
  @moduledoc """
  The Pubky Ring sign-in flow (grant + proof of possession), as a pure state
  machine that a LiveView, a GenServer or a script can drive.

      flow = Pubky.Auth.GrantFlow.start(caps: ["/pub/my-app/:rw"])
      render_qr(Pubky.Auth.GrantFlow.authorization_url(flow))
      {:ok, session} = Pubky.Auth.GrantFlow.await(flow, 120_000)

  Steps: the app makes a client secret and a proof-of-possession keypair, shows
  the deep link, polls the relay until Pubky Ring drops the encrypted grant,
  decrypts it, resolves the user's homeserver, and exchanges grant + proof for
  a `Pubky.Session`. Use `Pubky.Auth.GrantFlow.Poller` to run the polling in a
  separate process that reports back with messages.
  """

  alias Pubky.Auth.{Capability, DeepLink, Exchange, Grant, RelayChannel}
  alias Pubky.{Config, Keypair, Resolver, Session}

  @type state :: :polling | :approved | :done | :expired | :failed
  @type failure ::
          :expired
          | :decrypt
          | :grant_mismatch
          | :homeserver_unresolved
          | {:relay, term()}
          | {:exchange, term()}
          | term()

  @type t :: %__MODULE__{
          kind: :signin | {:signup, Pubky.PublicKey.z32(), String.t() | nil},
          caps: [Capability.t()],
          client_id: String.t(),
          relay: String.t(),
          x_callback: map(),
          secret: <<_::256>>,
          client: Keypair.t(),
          url: String.t(),
          channel_url: String.t(),
          state: state(),
          deadline: integer(),
          failures: non_neg_integer(),
          grant: Grant.t() | nil,
          session: Session.t() | nil,
          error: failure() | nil,
          config: Config.t()
        }

  @derive {Inspect, only: [:kind, :client_id, :state, :error]}
  defstruct [
    :kind,
    :caps,
    :client_id,
    :relay,
    :secret,
    :client,
    :url,
    :channel_url,
    :deadline,
    :grant,
    :session,
    :error,
    :config,
    x_callback: %{},
    state: :polling,
    failures: 0
  ]

  @max_failures 3

  @doc """
  Starts a flow. Options: `caps:` (capability strings or structs; default
  `/:rw`), `kind:` (`:signin`, or `{:signup, homeserver, signup_token}`),
  `client_id:`, `relay:`, `x_callback:` (map of `x-*` params), `client:`
  (a fixed PoP keypair), `deadline_ms:`.
  """
  @spec start(keyword(), Config.t()) :: t()
  def start(opts \\ [], %Config{} = config \\ Config.get()) do
    caps = opts |> Keyword.get(:caps, [Capability.root()]) |> Enum.map(&to_cap/1)
    secret = :crypto.strong_rand_bytes(32)
    client = Keyword.get_lazy(opts, :client, &Keypair.generate/0)
    client_id = Keyword.get(opts, :client_id, config.client_id)
    relay = Keyword.get(opts, :relay, config.http_relay)
    kind = Keyword.get(opts, :kind, :signin)
    x_callback = Keyword.get(opts, :x_callback, %{})

    params = %{
      caps: caps,
      relay: relay,
      secret: secret,
      client_id: client_id,
      client_pk: Keypair.public_z32(client),
      x_callback: x_callback
    }

    url =
      case kind do
        :signin ->
          DeepLink.signin_grant(params)

        {:signup, hs, token} ->
          DeepLink.signup_grant(Map.merge(params, %{homeserver: hs, signup_token: token}))
      end

    %__MODULE__{
      kind: kind,
      caps: caps,
      client_id: client_id,
      relay: relay,
      x_callback: x_callback,
      secret: secret,
      client: client,
      url: url,
      channel_url: RelayChannel.url(relay, secret),
      deadline:
        System.monotonic_time(:millisecond) +
          Keyword.get(opts, :deadline_ms, config.flow_deadline),
      config: config
    }
  end

  @doc "The `pubkyauth://` URL to show as a QR code or open in Pubky Ring."
  @spec authorization_url(t()) :: String.t()
  def authorization_url(%__MODULE__{url: url}), do: url

  @doc """
  Polls the relay once. Returns `{:pending, flow}` while waiting, `{:approved,
  flow}` once a valid grant arrived (call `complete/1` next), or `{:error, flow}`
  with `flow.error` set when the flow expired or failed.
  """
  @spec poll_once(t()) :: {:pending, t()} | {:approved, t()} | {:error, t()}
  def poll_once(%__MODULE__{state: :polling} = flow) do
    cond do
      System.monotonic_time(:millisecond) > flow.deadline ->
        {:error, fail(flow, :expired)}

      true ->
        handle_poll(flow, RelayChannel.poll_once(flow.channel_url, flow.config))
    end
  end

  def poll_once(%__MODULE__{state: :approved} = flow), do: {:approved, flow}
  def poll_once(%__MODULE__{} = flow), do: {:error, flow}

  @doc "Exchanges the approved grant for a session."
  @spec complete(t()) :: {:ok, Session.t(), t()} | {:error, failure(), t()}
  def complete(%__MODULE__{state: :approved, grant: %Grant{} = grant} = flow) do
    with {:ok, hs} <- homeserver(flow, grant),
         :ok <- maybe_signup(flow, hs, grant),
         {:ok, session} <- exchange(flow, hs, grant) do
      {:ok, session, %{flow | state: :done, session: session}}
    else
      {:error, reason} -> {:error, reason, fail(flow, reason)}
    end
  end

  def complete(%__MODULE__{state: :done, session: session} = flow), do: {:ok, session, flow}
  def complete(%__MODULE__{error: error} = flow), do: {:error, error || :not_approved, flow}

  @doc "Blocks until approval and exchange complete, or `timeout_ms` elapses."
  @spec await(t(), non_neg_integer()) :: {:ok, Session.t()} | {:error, failure()}
  def await(%__MODULE__{} = flow, timeout_ms \\ 120_000) do
    flow = %{
      flow
      | deadline: min(flow.deadline, System.monotonic_time(:millisecond) + timeout_ms)
    }

    loop(flow)
  end

  defp loop(flow) do
    case poll_once(flow) do
      {:pending, flow} ->
        loop(flow)

      {:approved, flow} ->
        case complete(flow) do
          {:ok, session, _} -> {:ok, session}
          {:error, reason, _} -> {:error, reason}
        end

      {:error, flow} ->
        {:error, flow.error}
    end
  end

  @doc "State needed to resume a pending flow later (contains secrets; store briefly and securely)."
  @spec save(t()) :: %{
          url: String.t(),
          client_secret: binary(),
          kind: term(),
          deadline: integer()
        }
  def save(%__MODULE__{} = flow),
    do: %{
      url: flow.url,
      client_secret: flow.client.secret,
      kind: flow.kind,
      deadline: flow.deadline
    }

  @doc "Rebuilds a pending flow from `save/1` output."
  @spec restore(map(), Config.t()) :: {:ok, t()} | {:error, term()}
  def restore(%{url: url, client_secret: secret} = saved, %Config{} = config \\ Config.get()) do
    client = Keypair.from_secret(secret)

    with {:ok, params} <- DeepLink.parse(url),
         true <- params.client_pk == Keypair.public_z32(client) || {:error, :client_key_mismatch} do
      kind =
        case params.kind do
          :signin_grant -> :signin
          :signup_grant -> {:signup, params.homeserver, params.signup_token}
        end

      {:ok,
       %__MODULE__{
         kind: kind,
         caps: params.caps,
         client_id: params.client_id,
         relay: params.relay,
         x_callback: params.x_callback,
         secret: params.secret,
         client: client,
         url: url,
         channel_url: RelayChannel.url(params.relay, params.secret),
         deadline:
           Map.get(saved, :deadline, System.monotonic_time(:millisecond) + config.flow_deadline),
         config: config
       }}
    else
      {:error, _} = err -> err
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp handle_poll(flow, :timeout), do: {:pending, %{flow | failures: 0}}

  defp handle_poll(flow, {:ok, body}) do
    RelayChannel.ack(flow.channel_url, flow.config)

    with {:ok, plaintext} <- open(flow, body),
         {:ok, grant} <- decode_grant(flow, plaintext) do
      {:approved, %{flow | state: :approved, grant: grant}}
    else
      {:error, reason} -> {:error, fail(flow, reason)}
    end
  end

  defp handle_poll(%{failures: failures} = flow, {:error, reason}) do
    if failures + 1 >= @max_failures do
      {:error, fail(flow, {:relay, reason})}
    else
      Process.sleep(1_000)
      {:pending, %{flow | failures: failures + 1}}
    end
  end

  defp open(flow, body) do
    case RelayChannel.open(body, flow.secret) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> {:error, :decrypt}
    end
  end

  defp decode_grant(flow, plaintext) do
    with {:ok, grant} <- Grant.decode(plaintext),
         true <- grant.cnf == Keypair.public_z32(flow.client) || {:error, :grant_mismatch},
         true <- grant.client_id == flow.client_id || {:error, :grant_mismatch} do
      {:ok, grant}
    else
      {:error, :grant_mismatch} -> {:error, :grant_mismatch}
      {:error, _} -> {:error, :invalid_grant}
    end
  end

  defp homeserver(%{kind: {:signup, hs, _}}, _grant), do: {:ok, hs}

  defp homeserver(flow, grant) do
    case Resolver.homeserver_of(grant.iss, flow.config) do
      {:ok, hs} -> {:ok, hs}
      {:error, _} -> {:error, :homeserver_unresolved}
    end
  end

  defp maybe_signup(%{kind: {:signup, hs, token}} = flow, hs, grant) do
    case Exchange.signup(hs, grant, flow.client, token, flow.config) do
      :ok -> :ok
      {:error, reason} -> {:error, {:exchange, reason}}
    end
  end

  defp maybe_signup(_flow, _hs, _grant), do: :ok

  defp exchange(flow, hs, grant) do
    case Exchange.session(hs, grant, flow.client, flow.config) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, {:exchange, reason}}
    end
  end

  defp fail(flow, reason),
    do: %{flow | state: if(reason == :expired, do: :expired, else: :failed), error: reason}

  defp to_cap(%Capability{} = cap), do: cap

  defp to_cap(str) when is_binary(str) do
    case Capability.parse(str) do
      {:ok, cap} ->
        cap

      {:error, reason} ->
        raise ArgumentError, "invalid capability #{inspect(str)}: #{inspect(reason)}"
    end
  end
end

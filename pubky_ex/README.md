# pubky_ex

A pure-Elixir client for the [Pubky](https://pubky.org) protocol: public-key identities, PKARR discovery over HTTP relays, grant-based authentication with Pubky Ring, homeserver storage, and live event streams. No NIFs; runs anywhere OTP 27 runs.

Status: pre-release (0.1.0), verified against the Pubky mainnet relays and homeserver, a local `pubky-docker` testnet, and the Pubky Ring Simulator.

## What it does

| Area | Modules | Notes |
| --- | --- | --- |
| Identity | `Pubky.Keypair`, `Pubky.PublicKey`, `Pubky.Crypto.ZBase32` | Ed25519 via OTP `:crypto`; pubkys are 52-char z-base-32 |
| Discovery | `Pubky.Pkarr.*`, `Pubky.Resolver` | DNS wire codec, signed packets, relay fetch/publish, ICANN endpoint selection, ETS cache |
| Auth | `Pubky.Auth.GrantFlow`, `Pubky.Auth.GrantFlow.Poller`, `Pubky.Auth.LocalSigner`, `Pubky.Session` | Grant + proof-of-possession flow (QR deep link → relay → bearer), automatic refresh, SDK-compatible credential export |
| Storage | `Pubky.Storage`, `Pubky.Resource` | Public reads for anyone, authenticated writes, listings with cursors, both addressing schemes |
| Events | `Pubky.Events`, `Pubky.Events.Stream` | Supervised SSE subscription per homeserver with per-user cursors, reconnect with backoff, PubSub delivery |
| Crypto | `Pubky.Crypto.Blake3`, `Pubky.Crypto.Secretbox`, `Pubky.Auth.Jws` | Pure-Elixir BLAKE3 (official vectors), XSalsa20-Poly1305 via `kcl` (libsodium KAT), EdDSA JWS |

## Quick start

```elixir
# config/config.exs
config :pubky, network: :testnet, client_id: "my-app.example"
```

Sign in a user through Pubky Ring (show the URL as a QR code):

```elixir
flow = Pubky.Auth.GrantFlow.start(caps: ["/pub/my-app/:rw"])
IO.puts(Pubky.Auth.GrantFlow.authorization_url(flow))
{:ok, session} = Pubky.Auth.GrantFlow.await(flow, 120_000)
```

Read and write files:

```elixir
:ok = Pubky.Storage.put_json(session, "/pub/my-app/hello.json", %{hello: "world"})
{:ok, %{"hello" => "world"}} = Pubky.Storage.get_json(session.user, "/pub/my-app/hello.json")
{:ok, %{entries: entries}} = Pubky.Storage.list(session.user, "/pub/my-app/")
```

Follow changes live:

```elixir
{:ok, _pid} =
  Pubky.Events.start_stream(homeserver: session.homeserver, users: [{session.user, nil}],
    paths: ["/pub/my-app/"], subscriber: self())

receive do
  {:pubky_event, %Pubky.Events.Event{type: :put, path: path}} -> IO.puts("changed: #{path}")
end
```

Persist a login across restarts (the exported string is a bearer-equivalent secret):

```elixir
exported = Pubky.Session.export(session)
{:ok, session} = Pubky.Session.restore(exported)
```

## Development

```bash
mix deps.get && mix test                                   # unit tests (fake homeserver/relay/ring)
PUBKY_TESTNET=1 mix test --include testnet                 # against pubky-docker on localhost
mix test --only mainnet                                    # read-only checks against the public network
mix pubky.auth_demo                                        # interactive Ring Simulator sign-in
mix format && mix credo --strict
```

The local testnet: `git clone https://github.com/pubky/pubky-docker && cd pubky-docker && cp .env-sample .env && docker compose up homeserver -d`. Identities for manual testing come from the [Pubky Ring Simulator](https://simulator.pubkyring.app).

## Design notes

- Homeservers are reached through their ICANN endpoints only; Erlang's `:ssl` cannot do raw-public-key TLS (PubkyTLS).
- Relays are queried sequentially, never raced (`pkarr.pubky.app` allows 10 requests/minute).
- `Pubky.Session` is immutable; `Pubky.Session.call/3` refreshes the bearer and returns the session to keep.
- Event stream cursors are exclusive; a stream deduplicates replays after reconnecting.

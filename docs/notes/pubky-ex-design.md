# `pubky_ex` — library design (pure-Elixir Pubky client)

OTP app `:pubky`, hex package name `pubky_ex`, lives in `pubky_ex/` and is consumed by the Phoenix app as `{:pubky, path: "../pubky_ex"}`. Deps: `req ~> 0.7.4`, `kcl ~> 1.5.1`; test: `bypass ~> 2.1`. Stdlib `JSON`. No NIFs. Wire facts are in `pubky-protocol-notes.md`.

## Module map
```
lib/pubky.ex                      facade + docs
lib/pubky/application.ex          Finch pools (Pubky.Finch, Pubky.Finch.Streams), Resolver, Events registry/supervisor, Task.Supervisor
lib/pubky/config.ex
lib/pubky/keypair.ex  lib/pubky/public_key.ex
lib/pubky/crypto/{ed25519,z_base32,blake3,secretbox,b64}.ex
lib/pubky/pkarr/{dns,signed_packet,relay,endpoint}.ex
lib/pubky/resolver.ex
lib/pubky/http.ex
lib/pubky/auth/{jws,grant,pop,capability,deep_link,relay_channel,grant_flow,grant_flow/poller,exchange,credential,local_signer}.ex
lib/pubky/session.ex
lib/pubky/storage.ex  lib/pubky/storage/addressing.ex  lib/pubky/resource.ex
lib/pubky/events/{event,sse,stream,supervisor,feed}.ex  lib/pubky/events.ex
```

### `Pubky.Config`
```elixir
%Pubky.Config{
  network: :mainnet | :testnet | :custom,
  pkarr_relays: ["https://pkarr.pubky.org", "https://pkarr.pubky.app"],   # ordered, sequential
  http_relay: "https://httprelay.pubky.app/inbox/",
  plain_http_domains: ["localhost", "127.0.0.1"],
  homeserver_overrides: %{},        # %{"8pinxx…" => "http://localhost:6286"} skips PKARR
  client_id: "rooms.pubky.app",
  finch: Pubky.Finch, stream_finch: Pubky.Finch.Streams,
  request_timeout: 10_000, resolver_ttl: 300_000, negative_ttl: 30_000, features_ttl: 60_000,
  flow_deadline: 600_000
}
```
`mainnet/1`, `testnet/1` (relays `["http://localhost:15411"]`, relay `"http://localhost:15412/inbox/"`, override for the testnet homeserver), `get/0` from `Application.get_all_env(:pubky)`. Every public function takes an optional config as last arg.

### Keys & crypto
- `Pubky.Keypair` `%{secret: <<_::256>>, public: <<_::256>>}`: `generate/0`, `from_secret/1`, `public_z32/1`, `sign/2`.
- `Pubky.PublicKey.parse/1` → `{:ok, z32} | :error` (accepts `pubky` prefix; validates 52 chars → 32 bytes); `to_bytes/1`, `from_bytes/1`.
- `Ed25519`: `generate/0` (`:crypto.generate_key(:eddsa, :ed25519)`), `public_from_secret/1`, `sign/2` (`:crypto.sign(:eddsa, :none, msg, [seed, :ed25519])`), `verify/3`.
- `ZBase32`: `encode/1`, `decode/1` (drop trailing partial bits, reject unknown chars).
- `Blake3`: `hash/1` pure Elixir. IV `[0x6A09E667,0xBB67AE85,0x3C6EF372,0xA54FF53A,0x510E527F,0x9B05688C,0x1F83D9AB,0x5BE0CD19]`; flags CHUNK_START=1 CHUNK_END=2 PARENT=4 ROOT=8; block 64 B, chunk 1024 B; words LE; `compress(cv, m[16], counter, block_len, flags)` with state = cv ++ IV[0..3] ++ [counter_lo, counter_hi, block_len, flags]; 7 rounds of columns `(0,4,8,12)(1,5,9,13)(2,6,10,14)(3,7,11,15)` then diagonals `(0,5,10,15)(1,6,11,12)(2,7,8,13)(3,4,9,14)`; `G`: `a+=b+mx; d=rotr(d^a,16); c+=d; b=rotr(b^c,12); a+=b+my; d=rotr(d^a,8); c+=d; b=rotr(b^c,7)`; permutation `[2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8]`; finalize `s[i] ^= s[i+8]`. Chunk: cv=IV, counter=chunk index, first block |START, last |END; empty input = one zero block len 0 with both flags. Tree: split left = largest power of two < n chunks; parent = `compress(IV, left ++ right, 0, 64, PARENT)`; ROOT only on the final compress. Test with the official `test_vectors.json` (input = bytes 0..250 repeating).
- `Secretbox`: `encrypt(plain, key)` = `nonce(24) <> Kcl.secretbox(plain, nonce, key)`; `decrypt/2` via `Kcl.secretunbox/3` → `{:ok, plain} | :error`.
- `B64`: url no-pad encode/decode; `random_id/0` (22 chars).

### PKARR
- `Dns.decode/1` → `%Dns.Packet{header, questions, answers, authorities, additionals}`; `%Dns.RR{name (lowercase, no trailing dot), type, class, ttl, rdata}`; rdata `{:a, ip4} | {:aaaa, ip6} | {:txt, [bin]} | {:https | :svcb, %{priority, target, params: %{int => bin}}} | {:raw, bin}`. Names: labels, pointer `0xC0` (14-bit offset, follow with 16-jump cap), root → `""`. HTTPS/SVCB: `<<priority::16, rest>>` → target name parsed against the whole packet → SvcParams loop; decode key 3 port, 4 ipv4hint list, 6 ipv6hint list, 65280 http_port; others raw. Never crash: `{:error, {:truncated, offset}}`.
- `Dns.encode/1` (answers only, uncompressed): header `<<0::16, 0x8000::16, 0::16, an::16, 0::16, 0::16>>`; HTTPS rdata `<<0::16>> <> name(target)`. Must reproduce the `user_ihaqcth` fixture bytes.
- `SignedPacket`: `%{public_key, timestamp_us, packet, records}`; `decode_relay_payload(z32, body)` → `{:ok, t} | {:error, :too_short | :bad_signature | {:dns, r}}`; `encode_relay_payload/1`; `signable(ts, packet)` = `"3:seqi#{ts}e1:v#{byte_size(packet)}:" <> packet`; `build(keypair, rrs, ts)`; `resource_records(t, name)` (normalizes `_pubky`/`@`); `pubky_record(user_kp, hs_z32)`.
- `Relay.resolve(z32, cfg)` → `{:ok, sp} | {:error, :not_found | {:relay, status} | :unreachable}` (sequential relays, `retry: false`, 8 s); `publish(sp, cfg)` (PUT all, success if any 204).
- `Endpoint.from_packet/1` → `[%{priority, target, port, http_port, ipv4hints}]`; `icann_base_url(endpoints, cfg)` → `{:ok, url} | :error` (rules in protocol notes).
- `Resolver` GenServer + ETS `:pubky_resolver` (read_concurrency): `homeserver_of/2` → `{:ok, hs} | {:error, :not_found | :no_pubky_record | :invalid_target | term}`; `endpoint_of/2` → `{:ok, %{base_url, features}}`; `base_url_for_user/2` → `{:ok, {hs, base_url, features}}`; `features/1`; `invalidate/1`; `put_override/2`. TTLs: positive `min(rr.ttl, resolver_ttl)`, negative 30 s, features 60 s. In-flight dedupe map; fetches in Tasks.
- `Http.request(method, url, opts, cfg)` → `{:ok, %Req.Response{}} | {:error, term}` (`retry: false`, `decode_body: false`, UA `pubky_ex/<vsn>`); helpers `bearer/2`, `pubky_host/2`; non-2xx → `{:error, {:http, status, body}}`.

### Auth
- `Jws.sign(keypair, typ, claims :: [{k, v}])`, `signing_input/2`, `decode/1` → `{:ok, %{header, claims, signature, signing_input}} | {:error, …}`, `verify/2`. Header emitted as the literal `{"alg":"EdDSA","typ":<typ>}`; claims via an ordered-object encoder so bytes are reproducible.
- `Grant`: `%Grant{iss, client_id, caps, cnf, jti, iat, exp, jws}`; `decode/1`; `sign(user_kp, client_id:, caps:, cnf:, lifetime: 63_072_000, now:)` (claim order iss, client_id, caps, cnf, jti, iat, exp).
- `Pop.sign(client_kp, hs_z32, grant_id, now)` (aud, gid, nonce, iat).
- `Capability`: `parse/1`, `format/1`, `join/1`, `split/1`, `root/0`.
- `DeepLink`: `signin_grant/1`, `signup_grant/1`, `parse/1`. Build with `URI.encode_query/1` (www-form), `x-*` with `URI.encode(v, &URI.char_unreserved?/1)`.
- `RelayChannel`: `channel_id/1`, `url/2`, `link?/1`, `poll_once/2` → `{:ok, bin} | :timeout | {:error, term}` (`receive_timeout: 35_000`; 408/timeout → `:timeout`), `ack/2`.
- `GrantFlow` struct `{kind, caps, client_id, relay_base, x_callback, client_secret, client_kp, url, channel_url, link?, state, started_at, deadline, consecutive_failures, grant, session, error}`; states `:polling → :approved → :exchanging → :done | :expired | :failed | :cancelled`. Pure API: `start/2`, `authorization_url/1`, `save/1`, `restore/2`, `poll_once/1` → `{:pending, t} | {:approved, t} | {:error, t}`, `complete/1` → `{:ok, session, t} | {:error, reason, t}`, `await/2` (blocking loop), `cancel/1`. `GrantFlow.Poller.start_link(flow, notify: pid, ref: ref)` sends `{:pubky_auth, ref, {:ok, %Session{}} | {:error, reason}}` (`:expired | :decrypt | :grant_mismatch | :homeserver_unresolved | {:relay, _} | {:http, status, body}`).
- `Exchange.session(hs, grant, client_kp, cfg)` → `{:ok, %Session{}}`; `signup(hs, grant, client_kp, signup_token, cfg)` → `:ok`.
- `Credential` `%{grant_jws, client_secret, homeserver}`: `from_session/1`, `export/1`, `import/1`, `restore/2` (checks `exp`, `cnf` matches the secret's public key, then Exchange).
- `LocalSigner`: `signup(user_kp, hs, opts, cfg)` (signup grant `client_id "pubky.signup"`, caps `["/:rw"]`, lifetime 300; then `publish_homeserver`), `signin(user_kp, hs | nil, opts, cfg)` → `{:ok, %Session{}}`, `publish_homeserver(user_kp, hs, cfg)`.
- `Session` immutable struct `{user, homeserver, base_url, features, token, token_expires_at, grant_expires_at, grant_id, client_id, capabilities, created_at, credential}`: `needs_refresh?/2`, `refresh/2` (401/403 → `{:error, :grant_revoked}`), `ensure_fresh/2`, `call/3` (`{:ok, result, session} | {:error, reason, session}`; retries once after refresh on 401), `info/2`, `signout/2`, `list_grants/2`, `revoke_grant/3`, `export/1`.

### Storage
- `Storage.get(target, path, opts, cfg)` → `{:ok, %{body, content_type, etag, last_modified, status}} | {:error, :not_found | :not_modified | {:http, st, body} | term}` (`if_none_match:`, `verify:` blake3 vs ETag). `target` = user z32 (public) or `%Session{}`.
- `head/3`, `exists?/3`, `list(target, dir, [limit:, cursor:, reverse:, shallow:], cfg)` → `{:ok, %{entries: [%Resource{}], next_cursor}}`, `put(session, path, body, [content_type:], cfg)` → `:ok | {:error, …}`, `put_json/4`, `delete/3`, `get_json/3`.
- `Addressing.target(base_url, features, user, path)` → `{url, headers}`.
- `Resource.parse("pubky://<z32>/pub/x")` → `{:ok, %{user, path}}`; `to_string/1`.

### Events
- `SSE.new/0`, `feed(parser, chunk)` → `{[frame], parser}`; `Event.from_sse/2`; `%Event{type, user, path, uri, cursor, content_hash, homeserver}`.
- `Stream` GenServer per `{homeserver, name}` (Registry + DynamicSupervisor, `restart: :transient`): opts `homeserver, name, users: [{z32, cursor|nil}] (≤50), paths, live, limit, subscriber, pubsub: {mod, topic}, session, config`. Req `into: :self` on `stream_finch`, `receive_timeout: 60_000`; `handle_info` routes `Req.parse_message`; `Req.cancel_async_response/1` on stop. Reconnect with exponential backoff 1–30 s + jitter (reset after first frame); 400/401/403 at connect → stop; 429 at connect → `{:disconnected, {:rate_limited, ms}}` and a retry after `Retry-After` (or the backoff). `add_users/2`, `remove_users/2` (debounced reconnect; a stream left with no users closes its connection and waits for `add_users/2` instead of sending an empty subscription, which homeservers reject with 400), `cursors/1`, `stop/1`. Delivers `{:pubky_event, %Event{}}` and status `{:pubky_stream, {hs, name}, :connected | {:disconnected, r} | {:error, r}}`. Transport behind a behaviour (`connect/2`, `handle_message/2`, `cancel/1`) so raw Mint can replace Req.
- `Events.start_stream/1`, `whereis/2`; `Feed.page(hs, cursor, limit, cfg)` for `/events/`.

## Tests
- Unit vectors: z32 (above), Ed25519 RFC 8032 §7.1 TEST 1, BLAKE3 official vectors (+ `blake3("") = af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`), libsodium secretbox KAT, JWS header strings, PKARR fixtures (`docs/fixtures/pkarr`), DNS edge cases (truncation, pointer loops), Credential round trips, DeepLink round trips, SSE parser (CRLF, chunk splits, comments).
- Bypass HTTP tests: relay 408→200 poll, ACK, `/info` fallback → legacy addressing (`pubky-host`), exchange/refresh/401 retry, storage status mapping, listing parse, stream reconnect with `user=<z32>:<cursor>`, 400 → no retry.
- `@tag :testnet` (`PUBKY_TESTNET=1 mix test --include testnet`): LocalSigner signup → resolve → signin → put/get/list/delete → ETag check → `/priv/` 401 → live stream put/del with forced reconnect → credential export/restore → forced refresh → signout → `:grant_revoked`.
- `@tag :manual`: `mix pubky.auth_demo` with the Ring Simulator.
- Mainnet smoke (`PUBKY_MAINNET=1`): resolve `ihaqcth…` → `8um71…` → `https://homeserver.pubky.app`; `/info` features; public GET of `/pub/pubky.app/profile.json`.

## Build order and risks
1. Scaffold + Config + Application + Http. 2. z32/keys/Ed25519. 3. DNS + SignedPacket + Relay + Endpoint + Resolver (risk #1; testable on mainnet fixtures). 4. BLAKE3 + Secretbox + B64. 5. JWS/Grant/PoP/Capability/Exchange/Session/Credential. 6. DNS encoder + publish + LocalSigner, then Storage (risk #2: PoP clock window, 201/204, testnet localhost). 7. DeepLink/RelayChannel/GrantFlow/Poller (risk #3: Simulator). 8. SSE + Stream (risk #4: Req/Finch long-lived). 9. Facade, docs, auth_demo, mainnet smoke.

## Hardening (2026-09-30 review)
`Pubky.Http.request/4` reads bodies through a Req `into:` collector: `:max_body` (default `Config.max_body`, 1 MiB) and `:deadline` (default 3 × `request_timeout`) abandon a response with `{:error, {:body_too_large, limit}}` / `{:error, {:transport, :deadline}}`; a declared `Content-Length` above the cap is refused before any chunk is kept; callers that pass their own `into:` own their limits. `Pubky.Events.SSE` refuses lines and frames past `max_bytes/0` (64 KiB) with `{:error, :frame_too_large}`, which the stream treats as a disconnect. `Pubky.Pkarr.Endpoint.icann_base_url/2` skips non-public targets unless `Config.allow_private_hosts` (testnet preset) — `public_host?/1` is the syntactic policy (non-strict literal parsing, alphabetic top-level label, reserved suffixes), `resolves_public?/1` the address check the `Resolver` applies to the chosen name (`{:error, :private_endpoint}`), and the plain-HTTP SvcParam counts only for `plain_http_domains` or with private hosts allowed. `Pubky.Http` never follows redirects. `Resolver` floors positive TTLs at 60 s and turns a call timeout into `{:error, :timeout}`. `Events.Stream` resets its backoff only after a connection that outlived the longest delay and cancels a pending reconnect before scheduling another; `Events.start_stream/1` takes `restart:` and `Events.stop_all_streams/0` exists for a subscriber that restarts. `ZBase32.decode/1` rejects non-zero padding bits, so `PublicKey.parse/1` accepts exactly one spelling per key. `Storage.Addressing` encodes per segment and refuses `.`/`..`; `Storage.list/4` clamps `limit` to 1000 and derives `next_cursor` from the raw line count. `Auth.GrantFlow.save/1` stores `deadline_in_ms`.

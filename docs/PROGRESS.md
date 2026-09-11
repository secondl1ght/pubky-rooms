# Progress

Legend: [ ] todo · [~] in progress · [x] done. See `docs/PLAN.md` for the full milestone definitions.

## M0 — prerequisites
- [x] Git repo, `.gitignore`, `CLAUDE.md`, `docs/` (plan, notes, ADRs, fixtures)
- [x] GitHub remote `secondl1ght/pubky-rooms` created and first push (private)
- [x] User installed Elixir/Erlang/Docker; docker group added (needs a fresh login before Claude's shell can use it)
- [x] `mix local.hex`, `mix local.rebar`, `mix archive.install hex phx_new` (Elixir 1.18.3 / OTP 27 / Phoenix 1.8.13)
- [~] `~/CODE/pubky-docker` cloned with `.env`; user must run `docker compose up homeserver -d` from a terminal with the docker group; verify `curl http://localhost:6286/info`

## M1 — pubky_ex core (keys, PKARR, resolver)
- [x] `mix new pubky_ex --sup`, deps (req, kcl; bypass for tests), `Pubky.Config`, `Pubky.Application`, `Pubky.Http`
- [x] `Pubky.Crypto.{Ed25519, ZBase32, B64}`, `Pubky.Keypair`, `Pubky.PublicKey`
- [x] `Pubky.Pkarr.Dns` decode/encode + fixtures; `Pubky.Pkarr.SignedPacket` verify/build; `Pubky.Pkarr.Relay`; `Pubky.Pkarr.Endpoint`
- [x] `Pubky.Resolver` (ETS cache, TTLs, dedupe, `/info` features)
- [x] Verified on mainnet (`mix test --only mainnet`): `ihaqcth…` → `8um71…` → `https://homeserver.pubky.app`; production homeserver has no `/info` and no path-addressed storage yet, legacy `pubky-host` reads work

## M2 — pubky_ex auth + storage
- [x] `Pubky.Crypto.Blake3` (all 35 official vectors incl. extended output), `Pubky.Crypto.Secretbox` (libsodium KAT)
- [x] `Pubky.Auth.{Jws, Grant, Pop, Capability, Exchange, Credential, LocalSigner}`, `Pubky.Session` (immutable; `call/3` refreshes on 401)
- [x] `Pubky.Storage` (+ `Addressing` path-addressed vs legacy `pubky-host`, `Pubky.Resource`, `public_url/3`)
- [x] `Pubky.Test.FakeHomeserver` (Bypass-backed in-memory homeserver + PKARR relay that verifies grants/PoPs) — 51 unit tests green, credo strict clean
- [x] Testnet verification passed (`PUBKY_TESTNET=1 mix test --include testnet`): signup → publish → resolve → signin → put/get/list/delete → 401 `/priv/` → 403 outside caps → restore → refresh → signout/revoke. Note: the current `synonymsoft/homeserver-testnet:latest` image (2026-08-19) has `/info` but advertises no features, so legacy `pubky-host` addressing is exercised, same as mainnet.

## M3 — pubky_ex grant flow + events
- [x] `Pubky.Auth.{DeepLink, RelayChannel, GrantFlow, GrantFlow.Poller}` with `FakeRelay` + `FakeRing` test doubles (full QR flow, mismatch/garbage/expiry, save/restore, signup flow)
- [x] `mix pubky.auth_demo` verified with the Pubky Ring Simulator (JS SDK 0.11): deep link parsed, grant encrypted by the Simulator, decrypted + exchanged by pubky_ex, file written
- [x] `Pubky.Events.{SSE, Event, Stream}` + supervisor/registry + `latest_cursor/4`; Cowboy-based `FakeHomeserver` (auth, storage, `/events-stream`, PKARR) and `FakeRelay`
- [x] Testnet verification: live put/del events, resubscribe on `add_users`, cursors; reconnect-from-cursor covered by unit test with a dropping fake

## M4 — Pubky Rooms vertical slice
- [ ] `mix phx.new pubky_rooms --no-ecto`, deps, presence
- [ ] 4a clean-room design system (tokens, fonts, lucide icons, UI components, shell)
- [ ] SessionStore, AuthLive + handoff, UserAuth
- [ ] Events.Cursors/dispatch/Subscriptions, RoomServer (minimal), Rooms context
- [ ] LobbyLive (create), RoomLive (send → pending → confirmed)
- [ ] Verify with two Simulator identities + app restart

## M5 — membership, presence, profiles
- [ ] Directory, join/leave, per-member backfill
- [ ] Presence sidebar, typing, lobby online count
- [ ] Profiles cache + avatars

## M6 — history, edits, replies, reactions, moderation, discovery
- [ ] older/infinite scroll, edit/delete, replies, reactions
- [ ] bans, local mute, rate limits
- [ ] lobby directory, room settings, universal tags + Nexus resources stream

## M7 — tests, release, deploy
- [ ] full test suites + CI
- [ ] `mix phx.gen.release --docker`, Fly.io deploy, mainnet test with real Ring
- [ ] README

## M8 — Pubky App integration
- [ ] summary API (`/api/rooms`), `?from=pubky.app`, OG tags
- [ ] on the fork `secondl1ght/pubky-app` (branch `rooms-integration`): routes, nav items, `/rooms` page, Nexus resources service, runtime config; user deploys the fork
- [ ] (later, at migration) upstream PR to `pubky/pubky-app`, repo transfer to the pubky org, `rooms.pubky.app` DNS

---

## Handoff note (update every session)
**Last session:** 2026-09-11 — M1–M3 complete: `pubky_ex` fully implemented (67 unit tests, 3 testnet integration tests, mainnet smoke test, credo strict clean) and verified against mainnet, the pubky-docker testnet, and the Pubky Ring Simulator.
**State:** library done for the app's needs. The Ring Simulator runs locally from `~/CODE/pubky-ring-simulator` (`npm run dev`, port 5173; the hosted one can't reach localhost from the in-app browser) — `.claude/launch.json` (gitignored) has a `ring-simulator` entry. Testnet containers: `cd ~/CODE/pubky-docker && docker compose up homeserver -d`.
**Next:** M4 — `mix phx.new pubky_rooms --no-ecto` in a **fresh session**: 4a design system port first (see `docs/notes/pubky-app-design-system.md`, `docs/notes/figma-reference.md`), then SessionStore/AuthLive/UserAuth, events plumbing, RoomServer, Lobby/Room LiveViews, verified with two Simulator identities in two browsers.
**Gotchas discovered so far:** mainnet `homeserver.pubky.app` has no `/info` and no `/storage/` routes yet (legacy `pubky-host` addressing only; SSE works); the Claude shell lacks the docker group until a fresh login (sandbox has no `newgrp`/`sg`); in Bash tool calls `cd X && cmd &` backgrounds the whole chain — use absolute paths; `pkarr.pubky.app` relay is limited to 10 req/min (use `pkarr.pubky.org` first, never race relays); testnet homeserver advertises ICANN target `localhost` with SvcParam key 65280 = plain-HTTP port 6286; resume cursor on `/events-stream` is exclusive; PoP `iat` must be within ±180 s of the homeserver clock; Nexus universal tags are keyed by the app namespace of the *tag file path*, not of the tagged URI.

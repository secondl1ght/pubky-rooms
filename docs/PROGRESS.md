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
- [x] `mix phx.new pubky_rooms --no-ecto` (stdlib JSON, no Swoosh/daisyUI/heroicons), deps (`pubky`, `eqrcode`, `lucide`, `mox`, credo, dialyxir), Presence
- [x] 4a clean-room design system: tokens in `app.css`, self-hosted Inter Tight, Lucide Tailwind plugin, `PubkyRoomsWeb.UI.*` (button, avatar, card, badge, tag with exact Pubky App colors, form, dialog, feedback, typography, layout), app shell (desktop header, mobile header + tab bar, FAB), `/dev/ui` styleguide; parity checked against pubky.app computed styles; `docs/design-system.md`
- [x] `Ids`, `Rooms.Paths`, `Rooms.{Room, Message, Membership}` schemas, `RateLimit`, `PubkyRooms.Pubky` façade (`Live` + test `Fake`), encrypted DETS `SessionStore`, `GrantLogin`, `AuthLive` (QR + deep link + copy), `/auth/complete` handoff, `/logout`, `UserAuth` plug/on_mount, `/me`
- [x] `Events` dispatch + `Cursors`, refcounted `Subscriptions` (homeserver sharding ≤50, cursor capture, retries), persistent `Directory`, `RoomServer` (sync bootstrap backfill, hash-confirmed pending writes, live message/member/room events, idle stop), `Rooms` context
- [x] `LobbyLive` (rooms lists, new-room dialog, FAB), `RoomLive` (stream, composer with Enter-to-send, pending/confirmed/failed states with retry/discard, join/leave, members aside, anonymous read-only)
- [x] Verified on the pubky-docker testnet with two Simulator identities in two browsers (in-app browser + Chrome): live cross-user delivery, join, and an app restart (history re-bootstrapped, both sessions restored from encrypted credentials, writes confirmed). 43 unit/LiveView tests, credo strict clean
- [x] Hardening after the M4 review (ADR 0005): grant credentials live in the encrypted httpOnly cookie, sessions cached in memory only (no DETS), `Secure` cookies in prod; bootstrap redesigned to merged listings + newest-K fetch with concurrency caps and `Retry-After` handling; rooms stay warm 30 min with an idle-room cap; sessions are dropped from memory 60 s after the last tab disconnects; unreachable member history is surfaced in the room (banner + retry, member marker) and retried every minute; "all rooms are public" and the trust model stated in the UI (sign-in, new-room dialog, `/me`) and README

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

## Design backlog (every design item not yet built, with its target; consume it, never let items live only in prose)
Source of truth for scope: `docs/PLAN.md` + `docs/notes/rooms-app-design.md`. At the end of each milestone run the **conformance pass** (CLAUDE.md, session protocol step 3): walk the design note sections for the modules touched and mark each item here as done ✓ / deferred → Mx / changed (with the reason in the notes).

| Item (design note / plan) | Target | Status |
|---|---|---|
| Room presence `presence:room:<ref>` + "N online", anonymous viewers untracked | M5 | open |
| Typing indicators (`room:<ref>:typing`, 2 s throttle, 1 s prune) | M5 | open |
| `Profiles` cache: pubky.app `profile.json` names, local nickname fallback, Nexus CDN avatars on mainnet, image resolution, `{:profile_updated}` broadcast | M5 | open |
| Lobby online count (`presence:lobby`) | M5 | open |
| `on_mount` tracks lobby presence | M5 | open |
| `older/3` + infinite scroll (`phx-viewport-top`), per-member listing cursors | M6 | open |
| Edit (PUT overwrite, `edited_at`) and delete, optimistic | M6 | open |
| Replies (`reply_to`, quote with 140-char truncation) | M6 | open |
| Reactions (`reactions/…` markers, palette, 20/10 s limit, bootstrap listing) | M6 | open |
| Bans (creator only, from creator's homeserver), banned composer disabled; local mute | M6 | open |
| Lobby "Public rooms" (visibility public, sorted by activity), live via `directory` topic | M6 | open |
| Room settings: rename/topic/close (room DEL → `:room_closed`) | M6 | open |
| Universal tags (`tags/<id>` PubkyAppTag) on public rooms + Nexus resources stream; tags in room header; add tags from Rooms | M6 | open |
| Detached per-room message cache (re-bootstrap "since last id") and incremental first paint for huge rooms | M6 | open |
| Message `:unconfirmed` state | — | changed: not needed (pending/confirmed/failed suffice) |
| `Subscriptions` own homeserver cache (`:user_homeservers`) | — | changed: uses `Pubky.Resolver`'s ETS cache |
| RoomServer `status/1`, `room/1`, `members/1`, `bans/1`, `verify/2` API | — | changed: `attach/2`/`snapshot/1` return one map; verification runs in the pending sweep |
| Telemetry events (streams, lag, bootstrap, send→confirm) per ADR 0006; `/healthz`; structured logs | M7 | open |
| CSP + secure headers; CORS for the API | M7/M8 | open |
| `mix phx.gen.release --docker`, Fly deploy, `PUBKY_DATA_DIR`, secrets, mainnet test with real Ring | M7 | open |
| PWA: manifest, minimal service worker, icons, theme color (push-ready) | M7 | open |
| `PUBKY_SERVICE_CREDENTIAL` authenticated reads (operator: whitelist first, service account if bandwidth throttle bites) | M7 | open |
| Full test suites + CI (GitHub Actions), dialyzer | M7 | open |
| README: architecture, credible exit, restart semantics, run locally, deploy | M7 | open (trust model section done) |
| `GET /api/rooms` summary API + `/api/rooms/featured` | M8 | open |
| `?from=pubky.app` back link, Open Graph tags per room, share to Pubky App | M8 | open |
| Pubky App fork: routes, nav items, `/rooms` page, Nexus resources service, runtime config | M8 | open |
| Auto-link URLs in message text safely (text rendering stays HTML-free) | M6 | open |
| Enforce/document `max_members_subscribed` (500) per room | M5 | open |
| `Subscriptions` unit tests (sharding at 50, refcount, owner DOWN, detach grace, retry) | M7 | open |
| `AuthLive` test with a fake grant flow (Mox or `PubkyRooms.Pubky`-style behaviour) | M7 | open |
| `@tag :testnet` end-to-end app test (sign-in via LocalSigner, create, send, confirm, restart) | M7 | open |
| `Events.Cursors` table growth (one row per user ever seen): bound or TTL | M7 | open |
| Trust-model text (sign-in, `/me`, README, ADR 0005) re-checked whenever session/credential handling changes | every session | rule |

## Handoff note (update every session)
**Last session:** 2026-09-11 (second session) — M4 complete: the Phoenix app `pubky_rooms` exists with the clean-room design system and the full vertical slice (sign in → create room → send → confirmed → second browser sees it live → restart keeps everything), verified on the testnet. `pubky_ex` also got the full credo suite enabled (it previously ran a single check) and the resulting cleanups.
**State:** `cd pubky_rooms && mix test` (43 tests) and `mix credo --strict` are green in both projects. Dev server: `.claude/launch.json` (gitignored) has `pubky-rooms` (`mix phx.server` in `pubky_rooms`, port 4000) and `ring-simulator` (port 5173) entries; the styleguide is at `/dev/ui`. Testnet containers: `cd ~/CODE/pubky-docker && docker compose up homeserver -d`. Two test identities exist only in the Simulators' memory (they vanish on reload); the room created during verification lives on the testnet homeserver (`/r/qj7kp5b3…ffp7o/0035PERXNDXFE`) until the containers are recreated. Local DETS state is in `pubky_rooms/priv/data/` (gitignored).
**Next:** M5 — membership/presence/profiles (also carry into M6: detached room message cache for cheap re-bootstrap, incremental first paint for huge rooms; into M7: `PUBKY_SERVICE_CREDENTIAL` for authenticated reads with an unlimited quota on the main homeserver, and ask the homeserver operator what `unauthenticated_ip_rate_read` / `[[drive.rate_limits]]` are set to on `homeserver.pubky.app`): `Presence` in rooms (topic `presence:room:<ref>`, "N online"), typing indicators, `Profiles` cache (pubky.app `profile.json`, avatars via Nexus CDN on mainnet), lobby online count. Then M6 (history paging, edit/delete, replies, reactions, bans, lobby directory + universal tags/Nexus) and M7 (release/Fly/PWA/README).
**Security/scale decisions from the post-M4 review (docs updated):** credentials in the browser cookie only (ADR 0005, README "Trust model"); merged newest-K bootstrap; homeserver limits verified in `pubky/pubky-homeserver` source: request-count limits are operator-configured per path (`429` + `Retry-After`, default only login), anonymous reads are bandwidth-throttled per IP (delay, not error), authenticated users get per-user quotas settable by the admin API.
**Conformance pass after M4 (2026-09-11) found and fixed:** the design's "capture cursors before listing history" guarantee had been lost when `Subscriptions.acquire` became async — `RoomServer` now captures every member's cursor (`Subscriptions.capture_cursor/1`) before any listing; `RoomLive` now monitors its room server and re-attaches (restarting it) if it crashes; `/login` redirects signed-in users; `unreachable` history is tracked and surfaced; stale plan text about cookies/DETS updated to ADR 0005. Missing test items were moved into the backlog table above.
**Design deviations from `docs/notes/rooms-app-design.md` made in M4 (notes updated):** `RoomServer` learns members from `Directory` broadcasts (`{:directory, {:member_joined | :member_left, ref, z32}}`) rather than from member events on user topics, because a joiner's own topic is not subscribed until they are a member; bootstrap backfill is synchronous (history complete at `:ready`), join backfills are async; `Subscriptions.acquire/release` are casts and resolution runs in tasks; `RoomLive` keeps its own pending messages in a `sent` map (stream items cannot be read back) so failures render with content; a `/me` page holds sign-out; `PubkyRooms.Pubky` is the façade behaviour with `Live` and a test `Fake` (in `test/support`) that emits events synchronously.
**Gotchas discovered so far:** LiveView `<.link>` rejects custom schemes as strings — pass `{:pubkyauth, "//…"}`; `JSON.decode/1` (stdlib) returns tuple errors, not a struct; `System.monotonic_time/1` can be negative (use `os_time` for bucketed rate limits); a GenServer must never call its own public API from a callback (Directory deadlock, fixed); in Chrome automation `navigator.clipboard` writes and JS results containing query strings are blocked — read the deep link from the accessibility tree and dispatch a synthetic paste event instead; the dev server must be restarted after `config/*.exs` or supervision-tree changes; mainnet `homeserver.pubky.app` has no `/info` and no `/storage/` routes yet (legacy `pubky-host` addressing only; SSE works); the Claude shell lacks the docker group until a fresh login (sandbox has no `newgrp`/`sg`); in Bash tool calls `cd X && cmd &` backgrounds the whole chain — use absolute paths; `pkarr.pubky.app` relay is limited to 10 req/min (use `pkarr.pubky.org` first, never race relays); testnet homeserver advertises ICANN target `localhost` with SvcParam key 65280 = plain-HTTP port 6286; resume cursor on `/events-stream` is exclusive; PoP `iat` must be within ±180 s of the homeserver clock; Nexus universal tags are keyed by the app namespace of the *tag file path*, not of the tagged URI.

# Progress

Legend: [ ] todo · [~] in progress · [x] done. See `docs/PLAN.md` for the full milestone definitions.

## M0 — prerequisites
- [x] Git repo, `.gitignore`, `CLAUDE.md`, `docs/` (plan, notes, ADRs, fixtures)
- [x] GitHub remote `secondl1ght/pubky-rooms` created and first push (private)
- [ ] User installs Elixir/Erlang/Docker (`sudo apt install -y elixir erlang inotify-tools docker.io docker-compose-v2`; `sudo usermod -aG docker $USER`)
- [ ] `mix local.hex`, `mix local.rebar`, `mix archive.install hex phx_new`
- [ ] Clone `pubky-docker` to `~/CODE/pubky-docker`, `docker compose up homeserver -d`, verify `curl http://localhost:6286/info`

## M1 — pubky_ex core (keys, PKARR, resolver)
- [ ] `mix new pubky_ex --sup`, deps (req, kcl; bypass for tests), `Pubky.Config`, `Pubky.Application`, `Pubky.Http`
- [ ] `Pubky.Crypto.{Ed25519, ZBase32, B64}`, `Pubky.Keypair`, `Pubky.PublicKey`
- [ ] `Pubky.Pkarr.Dns` decode/encode + fixtures; `Pubky.Pkarr.SignedPacket` verify/build; `Pubky.Pkarr.Relay`; `Pubky.Pkarr.Endpoint`
- [ ] `Pubky.Resolver` (ETS cache, TTLs, dedupe, `/info` features)
- [ ] Verify: `Pubky.Resolver.base_url_for_user("ihaqcth…")` → `{"8um71…", "https://homeserver.pubky.app", ["path-addressed-storage"]}`

## M2 — pubky_ex auth + storage
- [ ] `Pubky.Crypto.Blake3` (official vectors), `Pubky.Crypto.Secretbox` (libsodium KAT)
- [ ] `Pubky.Auth.{Jws, Grant, Pop, Capability, Exchange, Credential, LocalSigner}`, `Pubky.Session`
- [ ] `Pubky.Storage` (+ `Addressing`, `Pubky.Resource`)
- [ ] Testnet verification (signup, signin, put/get/list/delete, refresh, signout)

## M3 — pubky_ex grant flow + events
- [ ] `Pubky.Auth.{DeepLink, RelayChannel, GrantFlow, GrantFlow.Poller}` + `mix pubky.auth_demo`
- [ ] `Pubky.Events.{SSE, Event, Stream}` + supervisor/registry
- [ ] Testnet verification (Simulator approval; live stream put/del; reconnect with cursor)

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
**Last session:** planning + repo scaffold (2026-09-10).
**State:** no Elixir code yet. Toolchain not installed on the machine (needs the user's sudo). Plan approved; all research distilled into `docs/notes/`.
**Next:** once `elixir`/`docker` exist → M0 remaining items → M1 starting with z-base32, DNS parser, PKARR fixtures (`docs/fixtures/pkarr`, move into `pubky_ex/test/fixtures/pkarr`).
**Gotchas discovered so far:** `pkarr.pubky.app` relay is limited to 10 req/min (use `pkarr.pubky.org` first, never race relays); testnet homeserver advertises ICANN target `localhost` with SvcParam key 65280 = plain-HTTP port 6286; resume cursor on `/events-stream` is exclusive; PoP `iat` must be within ±180 s of the homeserver clock; Nexus universal tags are keyed by the app namespace of the *tag file path*, not of the tagged URI.

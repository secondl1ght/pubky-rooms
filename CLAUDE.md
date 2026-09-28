# Pubky Rooms — project memory (read this first every session)

Sovereign live chat rooms on the Pubky protocol, built with Phoenix/Elixir. Part of the Pubky "Vibes" initiative; production-quality target, to be hosted at rooms.pubky.app and integrated into Pubky App. **Not a hack project.**

## Where things are
- `docs/PLAN.md` — the approved plan (milestones M0–M8, data model, architecture). Keep it current.
- `docs/PROGRESS.md` — milestone checklist + **handoff note** (done / next / half-finished / gotchas). Update at every checkpoint. Start every session by reading it.
- `docs/notes/pubky-protocol-notes.md` — verified Pubky wire facts (PKARR, homeserver API, grant auth, SSE). Do not re-research; extend when something new is verified.
- `docs/notes/pubky-ex-design.md` — design of the `pubky_ex` library (modules, APIs, algorithms, tests).
- `docs/notes/rooms-app-design.md` — design of the Phoenix app (data model, processes, PubSub, LiveViews).
- `docs/notes/pubky-app-specs-mirror.md` — **living document**: every pubky-app-specs rule Rooms reimplements (Elixir cannot run the WASM package), pinned by `test/pubky_rooms/spec_mirror_test.exs` against `docs/fixtures/pubky-app-specs/`. Add a row whenever Rooms starts reading or writing anything spec'd; refresh the fixtures when the spec bumps.
- `docs/notes/pubky-app-design-system.md` — Pubky App design tokens/specs (reference data only; never copy their code).
- `docs/operations.md` — capacity limits table, what happens when each is hit, and the runbook (keep it current whenever a limit or config key changes).
- `docs/qa/` — `README.md` (how findings are recorded), `findings.md` (open items, decisions, gotcha-bugs), `checklist.md` (the manual pass: every flow with expected results; **smoke** subset before each deploy).
- `docs/design-system.md` — our clean-room component library (`PubkyRoomsWeb.UI.*`), tokens, and rules; gallery at `/dev/ui` in dev.
- `docs/adr/` — architecture decision records.
- `docs/fixtures/` — captured protocol payloads used by tests.

## Repo layout
```
pubky_ex/      Elixir library, OTP app :pubky (pure Elixir Pubky client; no NIFs)
pubky_rooms/   Phoenix 1.8 LiveView app, --no-ecto ({:pubky, path: "../pubky_ex"})
```

## Remotes and release path
- This repo → `github.com/secondl1ght/pubky-rooms` (user's account). Pubky App integration work → the user's fork `secondl1ght/pubky-app` on branch `rooms-integration`, checked out at `~/CODE/pubky-app`.
- Migration to the `pubky` org, the `rooms.pubky.app` domain, and the upstream `pubky/pubky-app` PR come **later**, after the project has been live on our own deployment and accepted into the ecosystem. Do not open upstream PRs.
- Push only when the user asks. Commit small and often locally.

## Conventions
- Elixir 1.18 / OTP 27, Phoenix 1.8.x, LiveView 1.2.x, Tailwind v4 CSS-first. Use stdlib `JSON`, not Jason. HTTP via `req` (+ Finch). Crypto: `:crypto` (Ed25519), `kcl` (XSalsa20-Poly1305), pure-Elixir BLAKE3 in `Pubky.Crypto.Blake3`.
- Clean-room UI: a small `PubkyRoomsWeb.UI.*` component library matching Pubky App's look via tokens; no code copied from `~/CODE/pubky-app`. Templates use these components (`<.button>`, `<.input>`, `<.dialog>`, `<.icon name="lucide-…">`, …), never raw daisyUI/heroicons (both removed).
- All homeserver access goes through the `PubkyRooms.Pubky` façade (`Live` in dev/prod, `Fake` in tests). Nexus (optional, mainnet) goes through `PubkyRooms.Nexus` (Req; tests stub it with `Req.Test` via `config :pubky_rooms, :nexus_req_options`). Tests touching the fake homeserver/directory use `PubkyRooms.RoomsCase` (`async: false`, `reset_state/0`). The dev server must be restarted after config or supervision-tree changes.
- No database. ETS for hot state; DETS only for the room directory. Login sessions are memory-only: the grant credential lives in the encrypted browser cookie (ADR 0005) and is never written to disk. Source of truth is always the users' homeservers.
- Every homeserver write is validated with the same limits the reader enforces. Anything taken from pubky-app-specs (tags, profile fields, ids, mutes path) is listed in `docs/notes/pubky-app-specs-mirror.md` and asserted against the vendored fixtures in `spec_mirror_test.exs`, in the same commit. Author identity always comes from the path/event owner, never from JSON bodies.
- Telemetry/logging (ADR 0006): aggregate counts and durations only, no identifiers in metric tags, nothing exported to third parties, no client-side analytics; logs at info+ carry no public keys, IPs or message content (truncated pubkeys at debug only). Every event goes through `PubkyRooms.Telemetry` (add new ones there and in `PubkyRoomsWeb.Telemetry.metrics/0`); `GET /healthz` is the platform health check.
- Scale story: cost is per room (bootstrap lists every member once and fetches only the newest `bootstrap_messages`), never per viewer; homeservers throttle anonymous reads per IP by bandwidth and may add 429 count limits — honor `Retry-After`, cap concurrency per fetch, keep rooms warm.
- Tests must stay green at every commit: `mix test` in each project, and `npm test` in `pubky_rooms/assets` for the LiveView hooks (vitest + jsdom, `assets/test/hooks/*.test.js`, helper `mountHook` in `assets/test/support/hook.js`; every hook change lands with a test). Testnet integration tests are tagged `:testnet` and excluded by default. CI (`.github/workflows/ci.yml`) runs format, credo strict, warnings-as-errors, tests and dialyzer for both projects plus the hook tests on every push. Test doubles live in `test/support`: `Pubky.Fake` (homeserver), `Auth.FakeGrantLogin` (Ring flow, `config :grant_login`), `Req.Test` for Nexus. What no suite covers: LiveView's own client (element locks, skip placeholders) — reproduce such races by hand with `liveSocket.enableLatencySim(400)`.
- Formatting/lint: `mix format`, `mix credo --strict`. Document public functions with `@doc`; every module has a `@moduledoc` explaining its role.
- Commit per completed step with descriptive messages. Never commit secrets, `.sess` files, or anything from `~/CODE/keys`.

## Commands
```bash
# toolchain (once): sudo apt install -y elixir erlang inotify-tools docker.io docker-compose-v2
# local Pubky testnet: (cd ~/CODE/pubky-docker && docker compose up homeserver -d)   # homeserver + relays on localhost
cd pubky_ex && mix deps.get && mix test                 # library
cd pubky_rooms && mix setup && mix phx.server           # app at http://localhost:4000 (styleguide: /dev/ui)
cd pubky_rooms && mix test && mix credo --strict        # app tests + lint
cd pubky_rooms/assets && npm ci && npm test             # LiveView hook tests (vitest + jsdom)
cd pubky_rooms && mix test --include testnet test/integration   # whole app against pubky-docker (real homeserver, SSE, sessions)
PUBKY_TESTNET=1 mix test --include testnet              # pubky_ex integration tests against pubky-docker
mix test --cover                                        # coverage (app ~83 %, library ~82 %); MIX_ENV=dev mix dialyzer (clean)
# in-app browser dev servers: .claude/launch.json (gitignored) → "pubky-rooms" (4000), "ring-simulator" (5173)
```

## Testnet constants
Homeserver `8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo` at `http://localhost:6286` (admin `:6288`, password `admin`), PKARR relay `http://localhost:15411`, HTTP relay `http://localhost:15412/inbox/`. Identities via the Pubky Ring Simulator run locally (`~/CODE/pubky-ring-simulator`, `npm run dev`, port 5173; Shortcut mode + paste the auth link) or `Pubky.Auth.LocalSigner` in tests. For two-identity checks use the in-app browser plus the connected Chrome (separate cookies).

## Session protocol
1. Read `docs/PROGRESS.md`; `git log --oneline -20`; run tests to confirm baseline.
2. Work in small committed steps.
3. Before ending a milestone: run the **conformance pass** — walk `docs/notes/rooms-app-design.md` (and the plan's milestone list) for every module touched and mark each item in the *Design backlog* table of `docs/PROGRESS.md` as done / deferred → Mx / changed-with-reason. Nothing may be silently skipped. Then update the handoff note, refresh this file if commands/conventions changed, commit.
4. Whenever session or credential handling changes, re-check the trust-model text in the sign-in page (the six points), `README.md` and ADR 0005 so it stays exact (`/me` shows only the signed-in-with and access-granted facts).

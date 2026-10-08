# Pubky Rooms — project conventions

Sovereign live chat rooms on the Pubky protocol, built with Phoenix/Elixir. Production-quality target, to be hosted at rooms.pubky.app and integrated into Pubky App. **Not a hack project.** This file is the conventions an agent (or a person) needs to change the code without breaking what the docs promise; the documents themselves are indexed in `docs/README.md`.

## Where things are
- `README.md` — what the app is, how it works, the trust model, how to run it. `CONTRIBUTING.md` — the suites, the commit rules, the PR flow.
- `docs/README.md` — index of every document under `docs/`.
- `docs/notes/pubky-protocol-notes.md` — verified Pubky wire facts (PKARR, homeserver API, grant auth, SSE). Do not re-research; extend when something new is verified.
- `docs/notes/pubky-ex-design.md` — design of the `pubky_ex` library (modules, APIs, algorithms, tests).
- `docs/notes/rooms-app-design.md` — design of the Phoenix app (data model, processes, PubSub, LiveViews). When a module's behaviour diverges from it, the note changes in the same commit (its "Implementation notes" sections record the deviations and their reasons).
- `docs/notes/pubky-app-specs-mirror.md` — **living document**: every pubky-app-specs rule Rooms reimplements (Elixir cannot run the WASM package), pinned by `test/pubky_rooms/spec_mirror_test.exs` against `docs/fixtures/pubky-app-specs/`. Add a row whenever Rooms starts reading or writing anything spec'd; refresh the fixtures when the spec bumps.
- `docs/notes/pubky-app-design-system.md` — Pubky App design tokens/specs (reference data only; never copy their code).
- `docs/operations.md` — capacity limits table, what happens when each is hit, the deploy steps and the runbook (keep it current whenever a limit or config key changes).
- `docs/qa/` — `README.md` (the test regime and how findings are recorded), `checklist.md` (the manual pass: every flow with expected results; **smoke** subset before each deploy).
- `docs/design-system.md` — our clean-room component library (`PubkyRoomsWeb.UI.*`), tokens, and rules; gallery at `/dev/ui` in dev.
- `docs/adr/` — architecture decision records. A new architectural decision gets a new ADR, never a silent change.
- `docs/fixtures/` — captured protocol payloads used by tests (`pkarr/` packets, `pubky-app-specs/` vectors, `nexus/` real staging Nexus responses).

## Repo layout
```
pubky_ex/      Elixir library, OTP app :pubky (pure Elixir Pubky client; no NIFs)
pubky_rooms/   Phoenix 1.8 LiveView app, --no-ecto ({:pubky, path: "../pubky_ex"})
```
Release files (`Dockerfile`, `.dockerignore`, `fly.toml`) sit at the repository root because the app depends on `pubky_ex/` by path. Pubky App integration work happens in a fork of `pubky/pubky-app`, not here; no upstream PRs until Rooms is accepted into the ecosystem.

## Conventions
- Elixir 1.18 / OTP 27, Phoenix 1.8.x, LiveView 1.2.x, Tailwind v4 CSS-first. Use stdlib `JSON`, not Jason. HTTP via `req` (+ Finch). Crypto: `:crypto` (Ed25519), `kcl` (XSalsa20-Poly1305), pure-Elixir BLAKE3 in `Pubky.Crypto.Blake3`.
- Clean-room UI: a small `PubkyRoomsWeb.UI.*` component library matching Pubky App's look via tokens; no code copied from the Pubky App repository (ADR 0004). Templates use these components (`<.button>`, `<.input>`, `<.dialog>`, `<.icon name="lucide-…">`, …), never raw daisyUI/heroicons (both removed). Every UI change is verified in a browser and shown as a screenshot, not described (`docs/qa/README.md`).
- All homeserver access goes through the `PubkyRooms.Pubky` façade (`Live` in dev/prod, `Fake` in tests). Nexus (optional, mainnet) goes through `PubkyRooms.Nexus` (Req; tests stub it with `Req.Test` via `config :pubky_rooms, :nexus_req_options`). Tests touching the fake homeserver/directory use `PubkyRooms.RoomsCase` (`async: false`, `reset_state/0`). The dev server must be restarted after config, struct or supervision-tree changes.
- No database. ETS for hot state; DETS only for the room directory. Login sessions are memory-only: the grant credential lives in the encrypted browser cookie (ADR 0005) and is never written to disk. Source of truth is always the users' homeservers.
- Whenever session or credential handling changes, re-check the trust-model text so it stays exact: the six points on the sign-in page, `README.md` "Trust model", ADR 0005 (`/me` shows only the signed-in-with and access-granted facts).
- Fire-and-forget tasks that report back to a server (`Task.Supervisor.start_child` + `send`) run their body under `PubkyRooms.SafeTask.run/2` with an explicit fallback, so a crash never leaves "in flight" state stuck. Every client-supplied id or key is validated (`Ids.valid_z32?`, `Ids.valid_id?`, `RoomLive.parse_dom_id/1`) and every LiveView has a catch-all `handle_event/3`: a crash report would log the socket's assigns.
- Every homeserver write is validated with the same limits the reader enforces. Anything taken from pubky-app-specs (tags, profile fields, ids, mutes path) is listed in `docs/notes/pubky-app-specs-mirror.md` and asserted against the vendored fixtures in `spec_mirror_test.exs`, in the same commit. Author identity always comes from the path/event owner, never from JSON bodies.
- Telemetry/logging (ADR 0006): aggregate counts and durations only, no identifiers in metric tags, nothing exported to third parties, no client-side analytics; logs at info+ carry no public keys, IPs or message content (truncated pubkeys at debug only). Every event goes through `PubkyRooms.Telemetry` (add new ones there and in `PubkyRoomsWeb.Telemetry.metrics/0`); `GET /healthz` is the platform health check. Never leave a live node at debug level.
- Scale story: cost is per room (bootstrap lists every member once and fetches only the newest `bootstrap_messages`), never per viewer; homeservers throttle anonymous reads per IP by bandwidth and may add 429 count limits — honor `Retry-After`, cap concurrency per fetch, keep rooms warm.
- Tests must stay green at every commit: `mix test` in each project, and `npm test` in `pubky_rooms/assets` for the LiveView hooks (vitest + jsdom, `assets/test/hooks/*.test.js`, helper `mountHook` in `assets/test/support/hook.js`; every hook change lands with a test). Every feature or fix lands with its tests in the same commit. Testnet integration tests are tagged `:testnet` and excluded by default. CI (`.github/workflows/ci.yml`) runs format, credo strict, warnings-as-errors, tests and dialyzer for both projects, the hook tests, the browser smoke, the VRT suite and the `testnet` job (both `:testnet` suites against the public pubky-docker homeserver image in Docker) on every push; docs-only pushes skip it, a newer push cancels the run in progress. A green run on `main` triggers `deploy.yml`: staging deploy with a scoped Fly token, then the post-deploy smoke (`pubky_rooms/scripts/deploy_smoke.js`, cookies of two staging identities as repository secrets, one unlisted smoke room) — the only layer that touches shared services, never the push gate. Test doubles live in `test/support`: `Pubky.Fake` (homeserver), `Auth.FakeGrantLogin` (Ring flow, `config :grant_login`), `Req.Test` for Nexus. The browser smoke suite (`test/e2e`, tag `:e2e`, excluded by default; CI job `e2e`) runs the checklist's **smoke** items in headless Chromium through `phoenix_test_playwright` against the same fakes, with the console collected by `PubkyRooms.E2E.Console` (a test fails on any console error or warning, CSP violations included); it needs the built bundle (`mix assets.build`), so rebuild after a hook change. The visual regression suite (`test/vrt`, tag `:vrt`, CI job `vrt`) compares eight screens with baselines in `test/vrt/snapshots` that only CI's Chromium generates (the "VRT baselines" workflow commits them; a missing baseline fails CI); after an intended visual change run that workflow, never edit the PNGs by hand. What no suite covers: LiveView's own client under latency (element locks, skip placeholders) — reproduce such races by hand with `liveSocket.enableLatencySim(400)`.
- Formatting/lint: `mix format`, `mix credo --strict`. Document public functions with `@doc`; every module has a `@moduledoc` explaining its role.
- Commit per completed step with a descriptive message. Never commit secrets, `.sess` files, session cookies or private keys. The repository documents the project, not the people working on it: no names, conversations, status tracking or working notes in committed files. Never stop or restart a running testnet homeserver container that others may be using (its identities and blobs are lost).

## Commands
```bash
# toolchain (once): Elixir 1.18 / OTP 27, Docker with compose v2, Node 20+, inotify-tools on Linux
# local Pubky testnet (homeserver + relays on localhost): docker compose up homeserver -d   # in a pubky-docker checkout
cd pubky_ex && mix deps.get && mix test                 # library
cd pubky_rooms && mix setup && mix phx.server           # app at http://localhost:4000 (styleguide: /dev/ui)
cd pubky_rooms && mix test && mix credo --strict        # app tests + lint
cd pubky_rooms/assets && npm ci && npm test             # LiveView hook tests (vitest + jsdom)
cd pubky_rooms && mix assets.build && mix test --include e2e test/e2e   # browser smoke suite (headless Chromium via phoenix_test_playwright; once: `cd assets && npx playwright install chromium`)
cd pubky_rooms && mix test --only vrt test/vrt                # visual regression against test/vrt/snapshots (baselines come from CI: `gh workflow run "VRT baselines"`, then git pull)
cd pubky_rooms && mix test --include testnet test/integration   # whole app against pubky-docker (real homeserver, SSE, sessions)
PUBKY_TESTNET=1 mix test --include testnet              # pubky_ex integration tests against pubky-docker
cd pubky_rooms && NODE_PATH=assets/node_modules ROOMS_URL=… SMOKE_ROOM=… SMOKE_ALICE_COOKIE=… SMOKE_BOB_COOKIE=… node scripts/deploy_smoke.js   # the post-deploy smoke by hand (docs/operations.md)
mix test --cover                                        # coverage (app ~83 %, library ~82 %); MIX_ENV=dev mix dialyzer (clean; an "Old PLT file" error means delete _build/dev/dialyxir_*.plt* and rebuild)
# Claude desktop app: dev servers are entries in the gitignored .claude/launch.json → "pubky-rooms" (4000), "ring-simulator" (5173)
```

## Testnet constants
Homeserver `8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo` at `http://localhost:6286` (admin `:6288`, password `admin`), PKARR relay `http://localhost:15411`, HTTP relay `http://localhost:15412/inbox/`. Identities via the Pubky Ring Simulator run locally (`pubky/pubky-ring-simulator`, `npm run dev`, port 5173; Shortcut mode + paste the auth link) or `Pubky.Auth.LocalSigner` in tests. For two-identity checks use two browsers (or profiles) with separate cookies. After a reboot the in-memory PKARR relay has forgotten every identity: older rooms render as closed archives with "live updates unavailable" (expected); make fresh identities.

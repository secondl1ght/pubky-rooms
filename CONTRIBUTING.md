# Contributing

Pubky Rooms is a production-quality app, not a hack project: every change lands with its tests, the docs that describe the changed behaviour change in the same commit, and the push gate stays green. This page is the short version; `CLAUDE.md` holds the project conventions in full (it is written for coding agents and reads fine for people), and `docs/README.md` indexes every document.

## Setup
Follow "Run locally" in the [README](README.md): the local Pubky testnet in Docker, the app, and the Ring Simulator for identities. Two browsers (or a normal and a private window) give you two identities.

## The suites
Everything CI runs can run locally; a pull request is expected to pass all of it.

```bash
cd pubky_ex && mix test && mix credo --strict && mix format --check-formatted
cd pubky_rooms && mix test && mix credo --strict && mix format --check-formatted
cd pubky_rooms/assets && npm ci && npm test                              # LiveView hook tests
cd pubky_rooms && mix assets.build && mix test --include e2e test/e2e    # browser smoke suite (once: cd assets && npx playwright install chromium)
cd pubky_rooms && mix test --only vrt test/vrt                           # visual regression against the committed baselines
cd pubky_rooms && mix test --include testnet test/integration            # the whole app against the running testnet
MIX_ENV=dev mix dialyzer                                                 # in each project
```

What each layer is for, and what stays manual, is in [`docs/qa/README.md`](docs/qa/README.md). The manual checklist in [`docs/qa/checklist.md`](docs/qa/checklist.md) is the pass to run after a change to sessions, the room server, the hooks or the shell; its **smoke** items take about fifteen minutes.

## Making a change
- One commit per completed step, with the tests in it. Tests stay green at every commit.
- Behaviour that the docs describe changes together with the docs: a new limit or config key updates [`docs/operations.md`](docs/operations.md); anything read or written that pubky-app-specs defines gets a row in [`docs/notes/pubky-app-specs-mirror.md`](docs/notes/pubky-app-specs-mirror.md) and an assertion in `spec_mirror_test.exs`; a divergence from [`docs/notes/rooms-app-design.md`](docs/notes/rooms-app-design.md) is recorded there; an architectural decision gets an ADR in [`docs/adr/`](docs/adr/); a new component or token is described in [`docs/design-system.md`](docs/design-system.md).
- Any change to sessions or credentials re-checks the trust-model text (the sign-in page, the README's "Trust model", ADR 0005) so it stays exact.
- UI changes come with a screenshot in the pull request, at desktop and phone widths when the layout is involved, and are verified in a browser, not only in tests (what LiveView's client does with locks, focus and dialogs is not visible to a render).
- Logging and telemetry follow ADR 0006: no public keys, IPs or message content at info level and above, aggregate metrics only.
- Templates use the `PubkyRoomsWeb.UI.*` components; nothing is copied from the Pubky App codebase (ADR 0004).
- Every LiveView hook change lands with a vitest test and a rebuilt bundle before the browser suite runs.

## Pull requests
- CI runs on every push and pull request: format, credo strict, warnings as errors, both test suites, the hook tests, the browser smoke, the visual regression suite, the testnet job and dialyzer. Docs-only pushes skip it.
- An intended visual change makes the `vrt` job fail until the baselines are regenerated. The "VRT baselines" workflow regenerates them with CI's Chromium and commits them to the branch; it pushes to this repository, so for a pull request from a fork a maintainer runs it after the change is in. Never edit the PNGs by hand.
- Deploys happen only from `main` of this repository, through `deploy.yml`, after a green CI run; pull requests never deploy.
- Keep secrets out of the tree: no `.sess` files, session cookies, private keys or tokens. The repository's secrets are used by the deploy workflow alone.

## Reporting a security issue
Use GitHub's private vulnerability reporting on this repository (Security → Report a vulnerability) rather than a public issue. Sessions, grants and homeserver writes are the sensitive surface; ADR 0005 describes the trust model.

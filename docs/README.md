# Documentation index

The [README](../README.md) explains what Pubky Rooms is, how it works, the trust model and how to run it; [CONTRIBUTING](../CONTRIBUTING.md) is how to change it; [CLAUDE.md](../CLAUDE.md) holds the project conventions in full.

## Design
- [`notes/pubky-protocol-notes.md`](notes/pubky-protocol-notes.md) — verified Pubky wire facts: PKARR, the homeserver API, grant auth, event streams.
- [`notes/pubky-ex-design.md`](notes/pubky-ex-design.md) — the `pubky_ex` library: modules, APIs, algorithms, tests.
- [`notes/rooms-app-design.md`](notes/rooms-app-design.md) — the Phoenix app: data model on the homeserver, processes, PubSub topics, LiveViews, and the implementation notes where the build diverged from the design.
- [`notes/pubky-app-specs-mirror.md`](notes/pubky-app-specs-mirror.md) — every pubky-app-specs rule the app reimplements, pinned by a test against the vendored fixtures.
- [`adr/`](adr/) — architecture decision records: server-side grant auth, no database, universal tags for discovery, clean-room UI, credentials live in the browser, telemetry and logging policy.

## UI
- [`design-system.md`](design-system.md) — the component library (`PubkyRoomsWeb.UI.*`), tokens and rules; gallery at `/dev/ui` in development.
- [`notes/pubky-app-design-system.md`](notes/pubky-app-design-system.md) — Pubky App's tokens and visual specs, recorded as reference data.
- [`notes/figma-reference.md`](notes/figma-reference.md) — the Figma file the tokens come from.

## Running it
- [`operations.md`](operations.md) — capacity limits and what happens at each, deploy targets and steps, the runbook, the telemetry contract.
- [`qa/README.md`](qa/README.md) — the test regime (which layer checks what, and what stays manual), how findings are recorded, how fixes are verified.
- [`qa/checklist.md`](qa/checklist.md) — the manual pass, with the **smoke** subset to run before a deploy.

## Test data
- [`fixtures/`](fixtures/) — captured protocol payloads used by tests: PKARR packets, pubky-app-specs vectors and limits, real Nexus responses. Each directory has its own README.

## Maintainers
- [`maintainers/`](maintainers/) — the maintainers' working notes.

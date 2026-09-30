# ADR 0006 — Telemetry and logging: aggregate only, no identifiers, nothing exported

**Status:** accepted (2026-09-11)

**Context.** Pubky Rooms relays public data but learns things a homeserver never sees: who is connected, which rooms they open, from which IP. The project wants the minimum observability needed to run the service well, and nothing that profiles people.

**Decision.**
- **Metrics** are Elixir `:telemetry` events aggregated locally (counts and durations only): stream connects/disconnects, event lag (cursor age), bootstrap duration, send→confirm latency, plus the default Phoenix/VM metrics. Metric tags never carry public keys, session ids, IPs, room refs or content. Consumers: LiveDashboard in dev; in production optionally a Prometheus/PromEx endpoint bound to a private interface. Nothing is sent to third parties.
- **No client-side analytics or tracking scripts**, ever. The only JavaScript is the LiveView client and our hooks.
- **Logs** at `info` and above contain no message content, no IP addresses and no public keys (homeserver keys are infrastructure identifiers and are allowed). User public keys may appear truncated at `debug` level only, which is off in production. Session ids appear truncated (they are opaque and short-lived). Credentials and bearer tokens are redacted from `inspect` by the library structs.
- **Rate limiting** keys on IPs and session ids live only in memory (ETS) for the window's duration.
- **Request lines** (`Plug.Telemetry`) are logged at `debug`, because room paths contain public keys; production runs at `info`, so no per-request log line is written by the app (the platform keeps its own access log; durations come from the telemetry events).
- **Retention:** we keep no request logs beyond the platform's default log buffer; no database of users exists.

**Consequences.** Operators can see health (are streams connected, how slow is bootstrap, how fast do writes confirm) without seeing who did what. Debugging a specific user's issue requires debug logging in a controlled environment. The README "Trust model" section states what the server sees; it must be updated if this policy changes.

**Implementation (2026-09-21).** All events are emitted by `PubkyRooms.Telemetry` (event table in its moduledoc), metrics are declared in `PubkyRoomsWeb.Telemetry`, and `GET /healthz` returns counts only. A test asserts that no metadata value is a public key or a structured term. Metric tags are bounded atoms (`status`, `via`, `reason`).

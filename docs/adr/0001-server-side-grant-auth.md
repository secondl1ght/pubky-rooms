# ADR 0001 — Server-side grant authentication in pure Elixir

**Status:** accepted (2026-09-10)

**Context.** Pubky apps authenticate users through Pubky Ring. v0.10 introduced grant auth: the app holds a proof-of-possession client key, Ring signs a grant bound to that key, and the app exchanges grant + PoP for hourly bearer tokens. The official SDKs are Rust and JavaScript; no Elixir client exists.

**Decision.** Implement the grant flow, PKARR resolution, storage, and event streams in pure Elixir (`pubky_ex`), and run the auth flow inside the Phoenix server (LiveView renders the QR; the server polls the relay and holds the credential). No cookie (deprecated) flow. No NIFs.

**Consequences.** Our server holds users' grant credentials (bearer-equivalent secrets) encrypted at rest; each app gets its own grant (a Pubky property), so Pubky App and Pubky Rooms sign in separately. We can talk to homeservers only through their ICANN endpoints (Erlang `ssl` cannot do raw-public-key TLS). The library is a reusable ecosystem contribution.

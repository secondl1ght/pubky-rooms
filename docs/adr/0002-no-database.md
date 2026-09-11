# ADR 0002 — No database: homeservers are the source of truth

**Status:** accepted (2026-09-10)

**Context.** Every room, membership, message, reaction, and ban is a file on its author's homeserver. Pubky's credible-exit principle is strongest when the app server keeps nothing users would lose.

**Decision.** `--no-ecto`. Hot state lives in ETS (per-room message caches, cursors, profiles); DETS holds only login sessions and a directory cache. On restart, rooms re-bootstrap from homeservers (directory listings + event cursors).

**Consequences.** Simple operations (single Fly machine, one volume for DETS); anyone can run a competing frontend over the same data. Trade-offs: cold-start latency when a room is first opened after a restart; discovery across the whole network relies on Nexus (universal tags) rather than our own index; clustering is out of scope for v1.

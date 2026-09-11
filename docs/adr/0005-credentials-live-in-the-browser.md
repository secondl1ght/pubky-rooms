# ADR 0005 — Grant credentials live in the browser cookie, never on disk

**Status:** accepted (2026-09-11). Amends ADR 0001.

**Context.** ADR 0001 has the Phoenix server perform homeserver writes on the user's behalf, which requires holding the user's Rooms grant (a Ring-signed authorization for a server-generated proof-of-possession key, scoped to `/pub/pubky-rooms/:rw`, revocable in Ring) together with the client secret that mints hourly bearer tokens. M4 stored these encrypted in a DETS file keyed from `SECRET_KEY_BASE`. That protects a stolen disk or backup, but the key lives on the same machine, so a compromised running server can decrypt every stored grant, and "your grant sits on their disk" is a hard sentence to defend to Pubky users.

Three options were weighed:

- **A.** Keep the store, harden it (separate key, grant list with revoke, documentation).
- **B.** Keep the credential only in the user's encrypted, signed, httpOnly session cookie; the server caches hydrated sessions in memory while the user is active and persists nothing.
- **C.** Move writes into the browser (grant in JavaScript-readable storage, browser mints tokens and PUTs files); the server only reads and relays.

Against an *active* compromise of the running server, B and C are equivalent: the server also serves the JavaScript, so an attacker can make every visiting browser use or leak its grant. Both protect fully against *passive* compromise (disk, backups, logs, dumps). C additionally exposes a two-year secret to XSS (it cannot be httpOnly), duplicates every write path in JavaScript, and makes server-side validation and rate limiting advisory. The only strictly stronger model is confirming each write in Pubky Ring, which is the UX the grant system exists to avoid.

**Decision.** Option B. `PubkyRooms.Auth.SessionStore` is an in-memory cache keyed by an opaque session id; the encrypted cookie carries `sid`, the user's public key and the exported credential. Every request re-seeds the cache from the cookie, so sessions survive restarts with nothing on disk. Entries idle for `session_memory_ttl_ms` are dropped. Sign-out clears the cookie and revokes the bearer; users can also revoke in Ring. Cookies are `SameSite=Lax`, httpOnly, encrypted and signed, 30 days, `Secure` in production. The credential is never assigned to a socket or conn and never appears in a URL (the post-login handoff passes only a single-use token; the controller reads the credential from memory).

**Consequences.** The honest one-liner is: *Rooms never sees your keys. Your grant lives only in your browser; while you are connected the server holds it in memory to write on your behalf and forgets it when you leave. It can only touch `/pub/pubky-rooms/` and you can revoke it in Ring at any time.* A leaked server image or backup contains no grants. A live compromise can act only as currently connected users, only inside the Rooms namespace, until revocation. C remains possible later as an opt-in "trustless mode", offered as a preference rather than sold as a security upgrade. DETS is now used only for the room directory.

# Pubky Rooms

Sovereign live chat rooms on the [Pubky](https://pubky.org) protocol, built with Phoenix LiveView.

Every message is a file the author writes to their **own homeserver**. This server stores nothing durable: it subscribes to members' homeserver event streams, fans updates out to connected browsers, and adds the live layer Pubky has no concept of (presence, typing, instant delivery). Anyone can run a competing frontend over the same data.

- `pubky_ex/` — pure-Elixir Pubky client library (identity, PKARR discovery, grant auth, storage, event streams).
- `pubky_rooms/` — the Phoenix application.
- `docs/` — plan, progress, protocol notes, design notes, ADRs.

## Trust model

- **Your keys never leave Pubky Ring.** Signing in gives Rooms a *grant*: a Ring-signed authorization for a key this server generates, limited to `/pub/pubky-rooms/:rw` on your homeserver, valid for the period Ring chooses (currently up to two years) and revocable in Ring at any time.
- **The grant lives in your browser.** It is stored in an encrypted, signed, httpOnly cookie that lasts 30 days or until you sign out. The server keeps a copy in memory while you have Rooms open, so it can write messages on your behalf, and drops it about a minute after your last tab closes. Nothing is written to disk, and the credential is redacted from logs (ADR 0005).
- **What a compromised Rooms server could do:** act inside `/pub/pubky-rooms/` as users who are connected at that moment (post or delete Rooms messages as them) until they revoke. It could not touch Pubky App data, sign in anywhere else, or change keys. This is the same trust you place in any web app that serves you code; the scoped, revocable grant is what bounds it.
- **All rooms are public**, like posts on Pubky App: everything is written under `/pub/`, readable by any Pubky client. "Unlisted" rooms are only left out of discovery. Private rooms wait for private homeserver storage.
- **What the server sees:** which rooms you open and when (presence), the messages of rooms it relays (already public), and your IP address. Homeservers see this server's IP, never yours. Drafts are not sent while typing.

Status: in development (see `docs/PROGRESS.md`). Part of the Pubky Vibes initiative.

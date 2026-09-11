# Pubky Rooms

Sovereign live chat rooms on the [Pubky](https://pubky.org) protocol, built with Phoenix LiveView.

Every message is a file the author writes to their **own homeserver**. This server stores nothing durable: it subscribes to members' homeserver event streams, fans updates out to connected browsers, and adds the live layer Pubky has no concept of (presence, typing, instant delivery). Anyone can run a competing frontend over the same data.

- `pubky_ex/` — pure-Elixir Pubky client library (identity, PKARR discovery, grant auth, storage, event streams).
- `pubky_rooms/` — the Phoenix application.
- `docs/` — plan, progress, protocol notes, design notes, ADRs.

Status: in development (see `docs/PROGRESS.md`). Part of the Pubky Vibes initiative.

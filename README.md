# Pubky Rooms

Sovereign live chat rooms on the [Pubky](https://pubky.org) protocol, built with Phoenix LiveView.

Every message is a file the author writes to their **own homeserver**. This server stores nothing durable: it subscribes to members' homeserver event streams, fans updates out to connected browsers, and adds the live layer Pubky has no concept of (presence, typing, instant delivery). Anyone can run a competing frontend over the same data.

- `pubky_ex/` — pure-Elixir Pubky client library (identity, PKARR discovery, grant auth, storage, event streams). Its own [README](pubky_ex/README.md) documents the API.
- `pubky_rooms/` — the Phoenix application.
- `docs/` — [index](docs/README.md): [protocol notes](docs/notes/pubky-protocol-notes.md), [app design](docs/notes/rooms-app-design.md), [operations](docs/operations.md), [QA](docs/qa/README.md), [design system](docs/design-system.md), [ADRs](docs/adr/).

Status: feature-complete and running on a staging deployment for the team's feedback; production follows. Part of the Pubky Vibes initiative; to be hosted at `rooms.pubky.app` and linked from Pubky App. Contributions: see [CONTRIBUTING.md](CONTRIBUTING.md).

## How it works

```
 browsers (LiveView over websocket)                 Pubky network
 ┌─────────────┐   ┌─────────────┐                 ┌───────────────────────────────┐
 │ RoomLive    │   │ LobbyLive   │    reads/lists  │ members' homeservers          │
 │ AuthLive/Me │   │             │ ◄──────────────►│  /pub/pubky-rooms/… (public)  │
 └──────┬──────┘   └──────┬──────┘   writes as you │  SSE /events-stream (≤50/conn)│
        │  PubSub, Presence│                        └──────────────┬────────────────┘
 ┌──────▼──────────────────▼──────────────────────┐              │ events
 │ Phoenix node                                   │ ◄────────────┘
 │  RoomServer (one per open room: ETS window,    │
 │    bootstrap, live events, paging, bans, polls)│   PKARR relays  → which homeserver serves a key
 │  Events.Subscriptions (refcounted streams)     │   HTTP relay    → Pubky Ring approvals (sign-in)
 │  Rooms.Directory (ETS + DETS cache of rooms,   │   Nexus (opt.)  → rooms tagged anywhere (mainnet)
 │    members, tags), Mutes, Profiles caches      │
 │  Auth.SessionStore (memory only)               │
 └────────────────────────────────────────────────┘
```

**Reading a room** costs *members + messages shown*, never members × messages, and nothing per viewer: `RoomServer` fetches the room definition from the creator, captures each member's event cursor, lists every member's message folder once (newest page), fetches only the newest `bootstrap_messages`, and then applies live events. Viewers share one process per room; scrolling up pages older history from the members' folders on demand. Members beyond the live-subscription budget are polled exactly (paging until a known message) instead of dropped.

**Writing** happens as the user: the browser holds the Pubky *grant* (see Trust model), the server mints a short-lived bearer from it and PUTs the message file to the author's homeserver. The message shows as pending until the author's own homeserver announces it over its event stream — the check mark means "stored on your homeserver", not "received by us".

**Ephemeral by design**: presence, typing, viewer counts, the mute/profile caches and the room directory live in memory (the directory also in DETS so a restart keeps what it learned). None of it is the source of truth; all of it is rebuilt from homeservers.

## Data on your homeserver

Everything Rooms writes lives under `/pub/pubky-rooms/` (the only capability it asks for, `/pub/pubky-rooms/:rw`). Every file is small JSON with `"v": 1`; the author is always the owner of the path, never a field in the body.

```
rooms/<room_id>                                 {v, name, topic, visibility, created_at}   the room (creator only)
members/<creator>/<room_id>                     {v, joined_at, room}                       your membership (DELETE = leave)
messages/<creator>/<room_id>/<msg_id>           {v, kind, content, reply_to, created_at, edited_at}   PUT again = edit, DELETE = delete
reactions/<creator>/<room_id>/<author>/<msg_id>/<key>   {v, created_at}                    DELETE = un-react
bans/<room_id>/<banned>                         {v, created_at, reason}                    honored only from the creator's homeserver
mutes/<muted>                                   {v, created_at}                            your mute list (Pubky App's is honored read-only)
tags/<hash_id>                                  {uri, label, created_at}                   PubkyAppTag on a room (discovery)
profile.json                                    {v, name}                                  optional local nickname
```

Ids are 13-character Crockford base32 microsecond timestamps, so a message's id orders it; keys are `{msg_id, author}`. Limits: name 64, topic 280, content 2000 characters; bodies over 16 KiB are ignored by readers. The full model with validation rules is in [`docs/notes/rooms-app-design.md`](docs/notes/rooms-app-design.md).

## Credible exit

If this server disappears tomorrow, nothing is lost and nothing is locked in:

- **Your files are yours.** Messages, memberships, reactions, tags and mutes are ordinary public files on your homeserver, readable by any Pubky client and deletable by you alone. Rooms never copies them anywhere durable.
- **Any client can rebuild a room** from public reads alone: fetch `rooms/<id>` from the creator, list each member's `messages/<creator>/<id>/` folder (newest first, cursors for older pages), merge by id, apply `bans/` from the creator's homeserver only, and toggle reactions from the marker paths. No secrets, no API keys, no server-side state are needed. `pubky_ex` does all of this and is meant to be extracted to Hex.
- **What you would lose** is the live layer (presence, typing, instant fan-out) and this node's *index*: who joined which room. Memberships are files on each member's homeserver, so a new frontend relearns them as members sign in or as their event streams report joins. Discovery of a room's full member list without an index is the one open protocol gap and is tracked for a post-launch decision (`docs/PROGRESS.md`, "member-list discovery").
- **Closing a room** deletes only the owner's definition file. Members' messages stay where they are and the room remains readable as an archive; writing the definition again reopens it.
- **Leaving a room takes your messages with you.** A room shows what its current members hold, nothing else. Your files stay on your homeserver, and joining again brings them back.
- **Signing out or revoking in Pubky Ring** ends this server's ability to write as you at once; the grant never leaves your browser cookie, and once Rooms notices a revoked grant it signs that browser out rather than keeping a dead session around.

## Restart semantics

There is no database. On restart:

- sessions come back from the browser cookie on the next request (the server keeps a copy in memory only while you have a tab open);
- the room directory reloads from DETS (`PUBKY_DATA_DIR/directory.dets`), so "Your rooms", memberships and tags are known immediately;
- rooms re-bootstrap lazily on first open (a burst of homeserver reads for popular rooms is expected), and event cursors are re-captured, so nothing written meanwhile is missed;
- presence, typing, viewer counts and the mute/profile caches start empty and refill.

One node serves everything; clustering is out of scope for v1 and would add nothing but shared presence.

## Trust model

- **Your keys never leave Pubky Ring.** Signing in gives Rooms a *grant*: a Ring-signed authorization for a key this server generates, limited to `/pub/pubky-rooms/:rw` on your homeserver, valid for the period Ring chooses (currently up to two years) and revocable in Ring at any time. Pubky grants are delegated app access; the holder may be a browser (as in Pubky App) or, as here, the server that renders the app.
- **The grant lives in your browser.** It is stored in an encrypted, signed, httpOnly cookie that lasts 30 days or until you sign out. The server keeps a copy in memory while you have Rooms open, so it can write messages on your behalf, and drops it about a minute after your last tab closes. Nothing is written to disk, and the credential is redacted from logs (ADR 0005).
- **What a compromised Rooms server could do:** act inside `/pub/pubky-rooms/` as users who are connected at that moment (post or delete Rooms messages as them) until they revoke. It could not touch Pubky App data, sign in anywhere else, or change keys. This is the same trust you place in any web app that serves you code; the scoped, revocable grant is what bounds it.
- **All rooms are public**, like posts on Pubky App: everything is written under `/pub/`, readable by any Pubky client. "Unlisted" rooms are only left out of discovery. Private rooms wait for private homeserver storage.
- **What the server sees:** which rooms you open and when (presence), the messages of rooms it relays (already public), and your IP address while you are connected (like any web server; it keeps only a keyed hash of it in memory for about a minute to limit sign-in attempts). Homeservers see this server's IP, never yours. Drafts are not sent while typing. Metrics are aggregate counts and durations with no identifiers, logs above debug level carry no public keys, IPs or content, and there are no analytics or tracking scripts (ADR 0006). Every HTML response carries a strict Content Security Policy that allows scripts and connections from this host only.

## Discovery: the tags and Nexus contract

Rooms are discoverable through Pubky's *universal tags* ([ADR 0003](docs/adr/0003-universal-tags-for-discovery.md)), so any client can list them without talking to this server:

- When a **public** room is created, the creator's homeserver gets `PubkyAppTag` files at `/pub/pubky-rooms/tags/<id>` whose `uri` is the room URI `pubky://<creator>/pub/pubky-rooms/rooms/<room_id>`: one automatic label `room` plus up to four creator-chosen labels (trimmed, lowercased, ≤ 20 characters); inside Rooms the automatic label shows on the room page and in the dialog, not on lobby cards, since every listed room has it. `id` is the pubky-app-specs hash id: the first 16 bytes of `blake3("<uri>:<label>")` in Crockford base32 (26 characters). Anyone signed in can add or remove their own tags on a listed room from its header; unlisting or closing a room deletes the creator's tags, and an unlisted room takes no new ones (tags other members added earlier stay on their own homeservers until they remove them).
- **Nexus** indexes those files under the `pubky-rooms` app namespace. To list rooms from anywhere: `GET https://nexus.pubky.app/v0/stream/resources?app=pubky-rooms&sorting=timeline|taggers_count&limit=100` returns room URIs with their tags and tagger counts; `GET /v0/resource/by-uri?uri=<room uri>` returns one room's tags from every app (including tags people add in Pubky App). Rooms itself is read-only towards Nexus and works without it (testnet, or a homeserver Nexus does not watch): its own directory learns rooms from sign-ins and events.
- Pubky App integration (a Rooms page listing these resources and linking to `/r/<creator>/<room_id>`) is the last milestone; a small summary API with live counts will accompany it.

## Run locally

Toolchain: Elixir 1.18 / OTP 27, Docker (for the local Pubky testnet) and Node 20+ (for the Ring Simulator).

```bash
# 1. local Pubky testnet: homeserver + PKARR and HTTP relays on localhost
git clone https://github.com/pubky/pubky-docker
cd pubky-docker && cp .env-sample .env && docker compose up homeserver -d
curl http://localhost:6286/info        # {"features":[...]}

# 2. the app (dev config points at the testnet)
cd pubky_rooms && mix setup && mix phx.server
# http://localhost:4000 — styleguide at /dev/ui, metrics at /dev/dashboard, health at /healthz

# 3. an identity to sign in with: the Pubky Ring Simulator
git clone https://github.com/pubky/pubky-ring-simulator
cd pubky-ring-simulator && npm install && npm run dev -- --port 5173
# on /login press "Copy link", paste it into the Simulator's Shortcut mode, done
```

Two identities in two browsers (or a normal and a private window) show the live layer: presence, typing, instant delivery, the pending → stored check mark.

Tests:

```bash
cd pubky_ex && mix test                                  # library (fixtures, vectors, Bypass homeserver)
cd pubky_rooms && mix test                               # app (in-memory homeserver and Ring doubles)
cd pubky_rooms/assets && npm ci && npm test              # LiveView hooks (vitest + jsdom)
cd pubky_rooms && mix assets.build && mix test --include e2e test/e2e   # browser smoke suite (headless Chromium)
cd pubky_rooms && mix test --include testnet test/integration   # the whole app against the running testnet
mix test --cover; mix credo --strict; MIX_ENV=dev mix dialyzer   # what CI runs on every push
```

## Configuration

Runtime configuration is read from the environment in `config/runtime.exs`:

| Variable | Purpose |
| --- | --- |
| `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, `PHX_SERVER` | standard Phoenix release settings (`PHX_HOST` is also the default `client_id` shown in Pubky Ring) |
| `PUBKY_NETWORK` | `mainnet` (default) or `testnet` |
| `PUBKY_CLIENT_ID` | the app id Ring shows and grants are bound to (defaults to `PHX_HOST`) |
| `PUBKY_PKARR_RELAYS`, `PUBKY_HTTP_RELAY`, `PUBKY_TESTNET_HOMESERVER_URL` | override the network's relays and the testnet homeserver endpoint |
| `PUBKY_DATA_DIR` | where the directory's DETS file lives (a volume in production) |
| `PUBKY_HTTP_POOL_SIZE`, `PUBKY_STREAM_POOL_SIZE` | connection pools per homeserver host; the stream pool bounds followed users (× 50) |
| `NEXUS_URL`, `NEXUS_CDN_URL` | enable Nexus discovery and Pubky App avatars on mainnet (`https://nexus.pubky.app`, `https://nexus.pubky.app/static`) |
| `PUBKY_APP_URL`, `PUBKY_RING_URL`, `PUBKY_SIMULATOR_URL` | links shown on `/login` for people who need an identity (the Simulator link only on testnet) |

Capacity limits, what happens when each is hit, the runbook and the telemetry contract are in [`docs/operations.md`](docs/operations.md).

## Deploy

One Fly.io machine per environment with a volume for the DETS directory. The release is standard Phoenix (`mix phx.gen.release --docker`); the `Dockerfile`, `.dockerignore` and `fly.toml` live at the repository root because the app depends on `pubky_ex/` by path, so the build context is the whole repo. `GET /healthz` is the health check and is excluded from the HTTPS redirect; behind Fly's proxy the sign-in rate limit keys on the client entry of `x-forwarded-for` (the one before Fly's own, appended last). Staging (`pubky-rooms-staging.fly.dev`, `PUBKY_NETWORK=staging`: Pubky's staging homeserver, HTTP relay and Nexus) and production (`rooms.pubky.app`, mainnet) are separate apps; the only secret is `SECRET_KEY_BASE`. Staging deploys from GitHub: a green CI run on `main` (static gate, both suites, hook tests, the browser smoke, the testnet integration job against a real homeserver in Docker) triggers the deploy workflow, which builds the image, deploys it with a scoped Fly token and runs the post-deploy smoke against the live app (`pubky_rooms/scripts/deploy_smoke.js`: health, headers, the worker, an anonymous lobby and room, Nexus, and the two staging identities meeting in one unlisted room). The exact commands, the local image check and the runbook are in [`docs/operations.md`](docs/operations.md) ("Deploy targets", "Deploy steps").

## Decisions

Architecture decision records live in [`docs/adr/`](docs/adr/): server-side grant auth (0001), no database (0002), universal tags for discovery (0003), clean-room UI (0004), credentials live in the browser (0005), telemetry and logging policy (0006).

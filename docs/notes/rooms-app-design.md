# Pubky Rooms — Phoenix app design

`pubky_rooms/`: `mix phx.new pubky_rooms --no-ecto`; OTP app `:pubky_rooms`, modules `PubkyRooms` / `PubkyRoomsWeb`. Deps: `{:pubky, path: "../pubky_ex"}`, `{:eqrcode, "~> 0.2.1"}`, `{:mox, "~> 1.1", only: :test}`. No Ecto/Postgres: ETS for hot state; DETS (under `data_dir`) only for login sessions and the room directory.

## On-homeserver data model (app id `pubky-rooms`, capability `/pub/pubky-rooms/:rw`)
```
/pub/pubky-rooms/
  rooms/<room_id>                                    RoomDef (creator only)
  members/<creator_z32>/<room_id>                    JoinMarker (DELETE = leave)
  messages/<creator_z32>/<room_id>/<msg_id>          Message (PUT overwrite = edit; DELETE = delete)
  reactions/<creator>/<room_id>/<author>/<msg_id>/<key>   Reaction marker (DELETE = un-react)
  bans/<room_id>/<banned_z32>                        Ban marker (honored only from creator's homeserver)
  mutes/<muted_z32>                                  Mute marker (the viewer's own list; Pubky App's /pub/pubky.app/mutes/ is honored read-only)
  tags/<hash_id>                                     PubkyAppTag on the room URI (public rooms; Nexus universal tags)
  profile.json                                       optional local nickname
```
- Room ref `{creator_z32, room_id}`; URL `/r/<creator>/<room_id>`; room URI `pubky://<creator>/pub/pubky-rooms/rooms/<room_id>`.
- `room_id`, `msg_id`: 13-char Crockford base32 of microsecond timestamp (`^[0-9A-HJKMNP-TV-Z]{13}$`), monotonic per node (`:atomics`, `max(now, last+1)`); lexical = chronological. Message sort key `{msg_id, author}`.
- All JSON carries `"v": 1`; unknown fields ignored; reader caps bodies at 16 KiB; author from path/event owner, never from body.
- RoomDef `{v, name (1..64), topic (≤280 | null), visibility "public"|"unlisted", created_at}`.
- JoinMarker `{v, joined_at, room: <room uri>}` (must match the path).
- Message `{v, kind: "text", content (1..2000, non-blank, no NUL), reply_to (same-room message uri | null), created_at, edited_at | null}`.
- Reaction `{v, created_at}`; key `^[a-z0-9_]{1,16}$`; v1 palette `up heart laugh eyes fire sad`.
- Ban `{v, created_at, reason (≤140)}`. LocalProfile `{v, name (1..32)}`.
- `PubkyRooms.Rooms.Paths.parse/1` → `{:room, id} | {:member, c, id} | {:message, c, id, msg_id} | {:reaction, c, id, author, msg_id, key} | {:ban, id, z32} | {:tag, id} | :profile | :ignore`.

## Modules
```
lib/pubky_rooms/
  application.ex            supervision tree
  ids.ex                    timestamp ids, z32 validation, monotonic next/0
  rate_limit.ex             ETS fixed-window limiter check(key, limit, window_ms)
  pubky.ex                  behaviour facade over pubky_ex (get/list/put/delete/latest_cursor/resolve/revoke)
  pubky/live.ex             real impl;  pubky/fake.ex  in-memory homeserver for tests (emits events synchronously)
  auth/session_store.ex     GenServer; DETS sessions.dets (credentials encrypted with a key derived from SECRET_KEY_BASE) + ETS :pubky_sessions
  auth/grant_login.ex       wraps Pubky.Auth.GrantFlow with app caps/client_id/relay
  events/dispatch.ex        stream sink: cursor advance + PubSub broadcast
  events/cursors.ex         ETS z32 -> last cursor
  events/subscriptions.ex   refcounted per-user subscriptions, homeserver grouping, 50-user sharding
  profiles.ex, profiles/cache.ex   pubky.app profile.json + avatar resolution, ETS TTL cache
  rooms.ex                  context: create_room, join, leave, send_message, edit, delete, react, ban, tag
  rooms/{room,message,paths,registry,room_server,directory}.ex
lib/pubky_rooms_web/
  router.ex, user_auth.ex (plug + on_mount), controllers/auth_controller.ex (complete, logout)
  live/{auth_live,lobby_live,room_live}.ex, live/room_live/components.ex
  ui/*.ex                   clean-room design system components
  presence.ex
assets/js/hooks/{scroll,clipboard}.js
```

## Supervision tree
```
PubkyRooms.Supervisor (one_for_one)
├── Telemetry, {Phoenix.PubSub, name: PubkyRooms.PubSub}, Pubky.Supervisor (library)
├── PubkyRooms.RateLimit, PubkyRooms.Events.Cursors, PubkyRooms.Auth.SessionStore, PubkyRooms.Profiles.Cache
├── {Task.Supervisor, name: PubkyRooms.TaskSupervisor}
├── {DynamicSupervisor, name: PubkyRooms.Events.StreamSupervisor}   # Pubky.Events.Stream per {homeserver, shard}
├── PubkyRooms.Events.Subscriptions, PubkyRooms.Rooms.Directory
├── {Registry, keys: :unique, name: PubkyRooms.Rooms.Registry}
├── {DynamicSupervisor, name: PubkyRooms.Rooms.RoomSupervisor}      # RoomServer per active room
├── PubkyRoomsWeb.Presence, PubkyRoomsWeb.Endpoint
```
Failure isolation: RoomServer crash loses only that room's cache (re-bootstrap on next `ensure/1`); stream crash restarts with cursors from `Events.Cursors`; node restart reloads DETS and rooms re-bootstrap lazily.

## Events topology
- `Pubky.Events.Stream` sink → `Events.dispatch/1`: `Cursors.advance(user, cursor)` (ignore ≤ last: dedupes replays) then broadcast `{:pubky_event, ev}` on `pubky:user:<z32>` and `pubky:all`.
- `Subscriptions.acquire(users, owner_pid)` / `release/2`: refcount per user; monitors owners; resolves homeserver (ETS `:user_homeservers`, 1 h TTL); picks a stream `{hs, shard}` with < 50 users or starts one; `add_user(pid, user, cursor)` with `cursor = Cursors.get(user) || latest_cursor(hs, user, "/pub/pubky-rooms/")` (SSE `reverse=true&limit=1`). Empty streams stop after 60 s grace. Owners: every RoomServer (members) and every signed-in LiveView (its own pubky).
- RoomServer subscribes `pubky:user:<member>` per member and ignores events not for its ref. Directory subscribes `pubky:all` for `{:room,_}` / `{:member,_,_}` only. Path filter on every stream `/pub/pubky-rooms/`.

## RoomServer (GenServer per active room)
State: `ref, room, status (:bootstrapping | :ready | :not_found | :closed), table (ETS ordered_set {msg_id, author} → %Message{}), members, bans, unreachable, pending (%{key => %{hash, msg, at}}), list_cursors (%{z32 => cursor | :done}), viewers (%{pid => monitor}), idle_timer`.
API via Registry: `ensure/1`, `attach/2`, `status/1`, `room/1`, `history/2` (reads ETS from caller), `older/3`, `members/1`, `bans/1`, `register_pending/3`, `cancel_pending/2`, `verify/2`.
Bootstrap (`handle_continue`): GET creator's RoomDef (404 → `:not_found`) → members = Directory ∪ {creator}; bans = list creator's `bans/<id>/` → `Subscriptions.acquire(members, self())` first (captures cursors) → per member reverse-list last 50 messages (`async_stream_nolink`, max_concurrency 8) + GET each (skip banned), insert → subscribe topics → `:ready` → broadcast. Replayed events are idempotent (same key + equal content ⇒ no broadcast).
Event handling: message PUT with pending hash match → `:confirmed` (no GET); else async GET → decode → upsert → broadcast `{:message_upserted, msg}`; DEL → `{:message_deleted, key}`; reactions update `reactions %{key => MapSet}`; bans (creator only) hide/unhide authors; room PUT → `{:room_updated}`; DEL → `:room_closed`. Membership casts from Directory `{:member_joined | :member_left, ref, z32}`. Pending sweep every 5 s: > 15 s → GET verify (exists → confirm; 404 → `{:message_failed, key, :vanished}`). Idle: 10 min after last viewer → release subscriptions, delete ETS, stop.
`older/3` → `{msgs, has_more?}` using ETS then one extra page per member with a live listing cursor.

## Send path
1. `send` event → `RateLimit.check({:msg, sid}, 5, 5_000)`.
2. Build `%Message{}` (`msg_id = Ids.next()`), encode, `hash = Blake3`.
3. `RoomServer.register_pending(ref, msg, hash)` **before** the PUT.
4. `stream_insert(:messages, msg)` with `state: :pending` (dom id `msg-<author>-<msg_id>`).
5. `start_async(:put, fn -> Pubky.put(sid, path, bytes, content_type: "application/json") end)`.
6. SSE PUT with matching `content_hash` → RoomServer confirms → broadcast → sender flips to "stored on your homeserver" check; others append.
7. `handle_async` failures → `:failed` with reason: quota (507), `{:rate_limited, secs}` (429), `:unauthorized` (session expired → SessionStore.delete + flash), `:unreachable`; Retry (same id/bytes) or Discard. Same pattern for edit/delete/react/join/leave/ban/create/tag.

## Auth
- `AuthLive` (`/login?return_to=`): `GrantLogin.start()` → `%{flow, auth_url}` → QR (`EQRCode.encode(url) |> EQRCode.svg(width: 256)`), copy link, `<a href={url}>Open in Pubky Ring</a>`, testnet hint → `start_async(:await, fn -> GrantFlow.await(flow, 120_000) end)` → `{:ok, session}` → `sid = SessionStore.put(session)` → `Phoenix.Token.sign(endpoint, "auth-handoff", sid)` → `redirect ~p"/auth/complete?token=…&return_to=…"`; timeout → "Code expired" + New code. Login starts rate-limited 10/min/IP.
- `AuthController.complete`: verify token (max_age 60 s), single-use guard (ETS), `put_session(:sid, sid) |> configure_session(renew: true)`, redirect to a local `return_to` or `/`.
- `SessionStore`: DETS `sessions.dets` `{sid, %{user, homeserver, secret (encrypted export), created_at, last_seen_at}}` + ETS `:pubky_sessions` `{sid, %Pubky.Session{}}` hydrated lazily; `lookup/1`, `put/1`, `update/2` (write back refreshed sessions), `delete/1`; hourly sweep of 30-day idle sessions.
- Cookie: `Plug.Session` cookie store, signed + encrypted, `max_age` 30 days, `same_site: "Lax"`, `secure` in prod; holds only `sid`.
- `UserAuth`: plug `fetch_current_user`; `on_mount :mount_current_user` (assign `current_user %{pubky, name, avatar_url}`, `sid`; when connected: `Subscriptions.acquire([z32], self())`, `Presence.track(self(), "presence:lobby", z32, %{})`, throttled `Directory.sync_user(z32)`); `on_mount :require_authenticated`.
- Logout: `DELETE /logout` → `Pubky.Session.signout` (best-effort) → `SessionStore.delete` → `configure_session(drop: true)`.

## Profiles
`Profiles.get(z32)` → `%Profile{pubky, name, avatar_url, source, fetched_at}` (cached; fallback `String.slice(z32, 0, 8)`), schedules fetch if missing/stale (TTL 15 min; in-flight dedupe): `GET <z32>:/pub/pubky.app/profile.json` (name 3..50) → else `/pub/pubky-rooms/profile.json` → fallback. Avatar: `{nexus_cdn_url}/avatar/<pubky>` when configured (mainnet), else resolve `image` (https as-is; `pubky://…/files/<id>` → File JSON `src` → `Pubky.Resolver.http_url`), else generative fallback. Broadcast `{:profile_updated, z32, profile}` on `"profiles"`.

## Presence / typing / lobby
`PubkyRoomsWeb.Presence` (`mix phx.gen.presence`) with `handle_metas/4` broadcasting `{:presence, {:join | :leave, %{key, metas}}}` on `"proxy:" <> topic`. Room topic `presence:room:<creator>/<room_id>` keyed by z32, meta `%{name, avatar_url, joined_at}`; anonymous viewers untracked. Typing: `room:<ref>:typing` `{:typing, z32, bool}` (throttled 2 s per LiveView; receivers prune with a 1 s tick). Lobby online count from `presence:lobby`.

## Directory
ETS `:rooms_directory {ref, %RoomSummary{ref, creator, room_id, name, topic, visibility, created_at, member_count, last_activity_at}}`, `:room_members` (bag), `:user_rooms` (bag `{z32, ref, :created | :joined}`), write-through to DETS `directory.dets`. Sources: `sync_user/1` (list `rooms/` + `members/` on the user's homeserver), `pubky:all` room/member events, RoomServer activity casts, and on mainnet Nexus `GET /v0/stream/resources?app=pubky-rooms&sorting=timeline|taggers_count`. Broadcasts `{:directory_updated, summary}` / `{:directory_removed, ref}` on `"directory"`.

## Moderation and limits
Creator ban/unban via ban markers (RoomServer hides messages; banned user's composer disabled); mutes persisted on the viewer's homeserver (+ Pubky App mutes read-only); content 2000 / topic 280 / name 64; per-sid limits: messages 5/5 s, reactions 20/10 s, rooms 5/h, joins 20/h; per-client sign-in starts 20/min (HMAC of the address, memory only); bootstrap concurrency 16; `max_members_subscribed` 5 000 per room with polling beyond it (see Implementation notes M5).

## PubSub topics
| topic | payloads |
|---|---|
| `pubky:user:<z32>`, `pubky:all` | `{:pubky_event, %Pubky.Events.Event{}}` |
| `room:<creator>/<room_id>` | `{:room_event, ref, ev}` with `ev` ∈ `:ready`, `{:unavailable, status}`, `{:message_upserted, %Message{}}` (also for reaction changes and edits), `{:message_deleted, key}`, `{:message_failed, key, reason}`, `{:member_joined, z32}`, `{:member_left, z32}`, `{:member_banned, z32, reason}`, `{:member_unbanned, z32}`, `{:unreachable, [z32]}`, `{:polled, [z32]}`, `{:live_unavailable, [z32]}`, `{:room_updated, %Room{}}`, `:room_closed` (the room became a read-only archive; `:ready` follows a reopen) |
| `room:<ref>:stats` | `{:room_stats, ref, %{viewers: n}}` (debounced viewer total, signed in or not) |
| `room:<ref>:typing` | `{:typing, z32, boolean}` |
| `proxy:presence:room:<ref>`, `proxy:presence:lobby` | `{:presence, {:join | :leave, %{key, metas}}}` |
| `directory` | `{:directory, {:room_updated, %Room{}} | {:room_removed, ref} | {:member_joined, ref, z32} | {:member_left, ref, z32} | {:tags_updated, ref}}` |
| `profiles` | `{:profile_updated, z32, %Profile{}}` |

`%Message{key, msg_id, author, room_ref, kind, content, reply_to, created_at, edited_at, state (:confirmed | :pending | :failed | :unconfirmed), fail_reason, uri, reactions}`.

## LiveViews and router
```elixir
pipeline :browser  # defaults + plug PubkyRoomsWeb.UserAuth, :fetch_current_user
live_session :default, on_mount: [{PubkyRoomsWeb.UserAuth, :mount_current_user}] do
  live "/", LobbyLive, :index
  live "/rooms/new", LobbyLive, :new
  live "/r/:creator/:room_id", RoomLive, :show
  live "/r/:creator/:room_id/settings", RoomLive, :settings   # creator only
  live "/login", AuthLive, :index
  live "/me", MeLive, :show
end
get "/auth/complete", AuthController, :complete
delete "/logout", AuthController, :logout
get "/api/rooms", Api.RoomsController, :index      # M8 summary API
```
- `RoomLive` assigns: `ref, room, status, current_user, sid, is_member, is_creator, banned?, members, bans, presences, typing, profiles, reply_to, editing_key, muted, pending_keys, oldest_key, has_more, composer_form, page_title`; stream `:messages`. Events: `send, typing, stop_typing, load_older, reply, cancel_reply, edit, save_edit, cancel_edit, delete, react, retry, discard, join, leave, ban, unban, mute, unmute`. Hooks: `ScrollToBottom` (stick within 80 px; preserve offset on prepend), `Clipboard`.
- `LobbyLive` assigns: `current_user, created, joined, public, online_count, form`; events `create_room`; `handle_async :create` (PUT RoomDef + PUT join marker + tags for public rooms → `push_navigate`).
- `AuthLive` assigns: `auth_url, qr_svg, state (:waiting | :expired | :error), return_to`.

## Config (`config/runtime.exs`)
```elixir
config :pubky_rooms,
  app_id: "pubky-rooms", data_dir: System.get_env("PUBKY_DATA_DIR", "priv/data"),
  client_id: System.get_env("PUBKY_CLIENT_ID", host), nexus_url: …, nexus_cdn_url: …,
  bootstrap_per_member: 50, bootstrap_messages: 100, page_size: 50, reactions_per_member: 1_000,
  max_members_subscribed: 5_000, member_poll_ms: 60_000, viewers_debounce_ms: 2_000, nexus_sync_ms: 300_000,
  room_idle_timeout_ms: 600_000, confirm_timeout_ms: 15_000, profile_ttl_ms: 900_000,
  session_max_idle_days: 30, pubky_backend: PubkyRooms.Pubky.Live
config :pubky, network: :mainnet | :testnet, pkarr_relays: [...], http_relay: "...", homeserver_overrides: %{}
```
Env: `SECRET_KEY_BASE`, `PHX_HOST`, `PORT`, `PUBKY_NETWORK`, `PUBKY_DATA_DIR`, `PUBKY_CLIENT_ID`, `NEXUS_URL`, `NEXUS_CDN_URL`, optional `PUBKY_PKARR_RELAYS`, `PUBKY_HTTP_RELAY`, `PUBKY_TESTNET_HOMESERVER_URL`.

## Flows
A. Login: AuthLive → GrantFlow.start → QR → approval in Ring/Simulator → relay returns → session → SessionStore → handoff token → `/auth/complete` cookie → `/` (on_mount acquires own events, presence, Directory.sync_user).
B. Create room: LobbyLive → `PUT rooms/<id>` + `PUT members/<self>/<id>` (+ tags if public) → navigate → own SSE events reach Directory.
C. Open room: RoomLive → `RoomServer.ensure` → bootstrap → `:ready` → stream history; presence tracked.
D. Send + confirm: see Send path.
E. Other member's message from any client: their homeserver SSE → stream → dispatch → RoomServer → GET → validate → broadcast → all viewers append.
F. Join: `PUT members/<creator>/<id>` → own event → Directory → RoomServer acquires member, backfills.
G. Restart: DETS reload; rooms re-bootstrap from homeservers on first open.

## Build order
Phase 0 toolchain + skeleton (ids, paths, schemas, tests). Phase 1 vertical slice (SessionStore, AuthLive, UserAuth; Cursors/dispatch/Subscriptions; RoomServer minimal; LobbyLive/RoomLive minimal; checkpoint with two Simulator identities + restart). Phase 2 Directory, join/leave, presence, typing, profiles. Phase 3 history, edit/delete, replies, reactions, bans, mute, rate limits. Phase 4 lobby directory, tags + Nexus, room settings, polish. Phase 5 tests, release, Fly deploy. Then M8 integration.

## Tests
`PubkyRooms.Pubky.Fake` (Agent-held `%{z32 => %{path => body}}`; put/delete emit `%Pubky.Events.Event{}` synchronously through `Events.dispatch`; `latest_cursor` from a counter); Mox for the auth flow. Unit: Ids, Paths, Message limits, RateLimit, Subscriptions sharding/refcount. RoomServer: bootstrap merge order, pending/confirm by hash, hash mismatch → GET, DEL, ban hides, idle stop releases, pagination. LiveView: handoff (cookie set, bad/expired/single-use), create → navigate, send pending → confirmed (`render_async`), second connection sees broadcast, presence, typing expiry, anonymous read-only, banned composer. `@tag :testnet`: end-to-end slice incl. app restart.

## Implementation notes (M4, 2026-09-11)
Deviations from the sections above, as built:
- **Membership events.** `RoomServer` subscribes to `pubky:user:<member>` for *messages* only. Joins/leaves/room changes arrive from `Directory` broadcasts on `"directory"` (`{:directory, {:member_joined | :member_left, ref, z32} | {:room_updated, room} | {:room_closed, room} | {:room_removed, ref}}`); the Directory itself watches `pubky:all`. A joiner's own topic is not subscribed until they are a member, so this is the only reliable path.
- **Bootstrap backfill is synchronous** (history is complete when `:ready` is broadcast); backfills for later joiners run in a task and flow through the normal `{:fetched, key, …}` path. Fetches use `Pubky.list(reverse: true, limit: bootstrap_per_member)` + one GET per entry (max concurrency 8 members × 4 files).
- **Subscriptions** API is cast-based (`acquire/2`, `release/2` never block); homeserver resolution and cursor capture run in `Task.Supervisor` tasks; streams are keyed `{hs, {:rooms, shard, unique}}`; a user with no owners detaches after 60 s, an empty stream stops 60 s later; failures retry every 30 s.
- **Façade.** `PubkyRooms.Pubky` is a behaviour (`get/list/put/delete/latest_cursor/homeserver_of/start_stream/add_users/remove_users/stop_stream`) with `PubkyRooms.Pubky.Live` and the test-only `PubkyRooms.Pubky.Fake` (`test/support/fake_pubky.ex`, emits events synchronously through `Events.dispatch/1`). Errors are normalized by `PubkyRooms.Pubky.normalize/1`.
- **SessionStore** (ADR 0005): memory only. ETS `{sid, %{user, export, session :: %Pubky.Session{} | nil, last_used}}`; the encrypted cookie holds `%{"sid", "pubky", "cred"}` and `ensure/1` re-seeds the cache from it on every request (no disk, survives restarts). Hydration (minting a bearer from the credential) happens inside the GenServer on first `lookup/1`. Connected LiveViews `attach/1`; the entry is dropped 60 s after the last one disconnects, and entries that never had a LiveView are swept after `session_memory_ttl_ms` (15 min). `%Pubky.Auth.Credential{}` redacts its secrets from `inspect`. `user_of/1` is the cheap, no-network check used by `UserAuth`. The credential is never assigned to sockets/conns and never travels in a URL.
- **Bootstrap (scale):** every member's `messages/` folder is listed once in parallel (`fetch_concurrency`, default 16), entries are merged by time-ordered message id, and only the newest `bootstrap_messages` (default 100) are fetched: cost is members + messages shown. 429s honor `Retry-After` (library maps them to `{:rate_limited, ms}`) with one retry. Rooms stay warm `room_idle_timeout_ms` (30 min) after the last viewer unless more than `max_idle_rooms` are alive. Homeservers throttle anonymous reads per IP by bandwidth (`unauthenticated_ip_rate_read`, e.g. 1 MB/s) and may add per-path request-count limits; a Rooms service account with an unlimited read quota on the main homeserver is the operator-side lever (M7 option `PUBKY_SERVICE_CREDENTIAL`). Members whose folder cannot be listed are tracked as `unreachable` (snapshot + `{:unreachable, [z32]}` broadcast), shown in the room UI with a Retry button and a marker in the member list, and retried every minute while viewers are attached. Deferred to M6 with history paging: a detached per-room message cache so re-bootstrap after idle lists "since last id", and incremental first paint for very large rooms.
- **RoomLive** keeps messages it sent in a `sent` map until confirmed (stream items cannot be read back) so failures render with content and can be retried; `failed` holds failed ones by DOM id. Composer: `Composer` hook (Enter sends, Shift+Enter newline, server pushes `composer:clear`).
- **Routes:** `/`, `/rooms/new` (dialog over the lobby), `/r/:creator/:room_id`, `/login`, `/me` (identity + sign out), `GET /auth/complete`, `DELETE /logout`, dev-only `/dev/ui`.
- **Ids** are Crockford base32 of the 64-bit µs timestamp + 1 zero pad bit (13 chars), matching pubky-app-specs; `Ids.next/0` is monotonic via `:atomics`.
- Everything listed here as "M6+" was built in M6; see the M6 notes below.

## Implementation notes (M5, 2026-09-11)
- **Profiles.** `PubkyRooms.Profiles.get/1` reads ETS only (never the network) and schedules a fetch through `PubkyRooms.Profiles.Cache` when the key is unknown or older than `profile_ttl_ms`; the fallback (shortened key) is returned meanwhile. Fetch order: `/pub/pubky.app/profile.json` (`name` ≤50, `image` ≤300) → `/pub/pubky-rooms/profile.json` (`PubkyRooms.Profiles.LocalProfile`, name 1..32) → fallback; `source` is `:pubky_app | :local | :fallback`. Avatar: `nexus_cdn_url` + `/avatar/<z32>` when configured **and** the profile has an image (so pictures match Pubky App and users without one keep the generative fallback); otherwise `image` is resolved (`http(s)://` as-is; `pubky://…/pub/pubky.app/files/<id>` → file record `src` → `Pubky.public_url`, which uses `?pubky-host=` on legacy homeservers). Failed fetches keep the previous profile with a 1-minute TTL; entries older than 4 × TTL are swept. The cache watches `pubky:all` and refreshes a user on their `profile.json` event (Pubky App profile changes are picked up at TTL because streams only carry `/pub/pubky-rooms/`). Broadcast `{:profile_updated, z32, profile}` on `"profiles"` only when the profile changed. `UserAuth.on_mount` subscribes and attaches a `handle_info` hook that refreshes `current_user`; Room/Lobby LiveViews keep a `profiles` map. Nickname UI on `/me` (`Rooms.set_nickname/2`, `clear_nickname/1`, 10 per 10 min), hidden when a Pubky App profile exists.
- **Presence.** `PubkyRoomsWeb.Presence` (`handle_metas/4` → `{:presence, {:join | :leave, %{key, metas}}}` on `"proxy:" <> topic`, local broadcast). Room topic `presence:room:<creator>/<id>`, app-wide `presence:lobby` (tracked from `UserAuth.on_mount` for every connected signed-in LiveView, so it counts users online anywhere in Rooms). Meta `%{name, avatar_url, joined_at}` but names render from the profiles map. `RoomLive` shows "N online" (header + members card), online dots, online-first member order and an "Also here" list of signed-in non-members; `LobbyLive` shows the app-wide count and a per-room online count on cards (`Rooms.online_count/1`, refreshed on lobby presence changes). Anonymous viewers are never tracked.
- **Typing.** Composer hook pushes `typing` (client throttle 2 s, `stop_typing` on empty/blur); `RoomLive` throttles again (2 s), broadcasts `{:typing, z32, bool}` on `Rooms.typing_topic/1`, receivers keep `z32 → expiry` (4 s), prune on a 1 s tick while non-empty, drop the author on their message, ignore their own signal, and send `false` on send. Nothing persisted.
- **Live budget.** `RoomServer` splits members into `subscribed` (creator first, then key order, up to `max_members_subscribed` = 5 000) and `polled`; polled members' folders are re-listed every `member_poll_ms` (60 s) while viewers are attached (`{:polled, [z32]}`, snapshot field, room notice + timer marker). All members' PubSub topics are subscribed regardless, so events still arrive when anyone else on the node follows them. `Subscriptions` now broadcasts `{:subscription_status, z32, :attached | {:error, reason}}` on `"subscriptions"` (per-user attach/failure and per-stream connect/disconnect); `RoomServer` tracks `live_unavailable` for subscribed members (`{:live_unavailable, [z32]}`, notice + wifi-off marker). `terminate/2` releases only `subscribed`.

## Implementation notes (M6, 2026-09-12)
- **Viewer counts.** Anonymous viewers are never tracked, only counted: `RoomServer` monitors every attached LiveView and announces `%{viewers: n}` on `RoomServer.stats_topic/1` at most once per `viewers_debounce_ms` (2 s); the snapshot carries `viewers`. Room header and members card show "N online · M anonymous" (`Rooms.anonymous_count/2` = viewers − signed-in *tabs*); lobby cards show the signed-in count and an eye icon with the anonymous count, subscribing to each listed room's stats and presence topics (`LobbyLive.load_viewers/1`).
- **History paging.** Not `phx-viewport-top` (the message list is an inner scroll container, which IntersectionObserver-based viewport events do not support): the `ScrollToBottom` hook pushes `load_older` when the reader is within 240 px of the top and `data-has-more` is set, and preserves the scroll offset when the page is prepended; a "Load earlier messages" button does the same for keyboard users. `RoomServer` keeps, per member, the listing entries that were not fetched at bootstrap plus the listing cursor (`older: %{z32 => %{entries, cursor, floor}}`); `older/3` serves from the table down to the *boundary* (newest unfetched entry across members) and otherwise runs extension rounds in a task (refill exhausted members with one listing each, pick the newest `page_size` entries across members, fetch them, insert **silently**, answer waiters; ≤ 5 rounds). Bulk `stream/4` with `at: 0` inserts items one by one, so pages are reversed before prepending. Polls and join backfills skip messages already held (`known_keys/2`), so a poll is one listing plus only new files.
- **Edit / delete / replies.** Edits reuse the send path (`Rooms.prepare_edit/3`: same id, `edited_at`, pending by hash); a failed edit puts the stored version back. Deletes are optimistic (`stream_delete`, then `Rooms.delete_message/2`; a failure re-inserts from the table). Both live in the composer as *modes* (`composer_mode: :new | {:edit, msg} | {:reply, msg}`) with a context bar, not inline in the stream item. Reply quotes are resolved at render time from the room table (`quote_of/2`, 140 chars, link to the original; "no longer available" when it is not held). Message rows carry hover actions (react, reply for members; edit, delete for the author).
- **Reactions.** `PubkyRooms.Rooms.Reaction` (palette `up heart laugh eyes fire sad`). No reaction body is ever fetched: bootstrap lists each member's `reactions/<c>/<id>/` once (`reactions_per_member` 1 000; the listing owner is the reactor) and PUT/DEL events toggle from the path alone. `RoomServer.reactions` maps message key → `%{key => MapSet reactors}`; the table row carries a copy so a change is one `{:message_upserted}` broadcast and viewers re-insert the row. A poll replaces a listed member's reactions wholesale (removals missed by events). Only members' markers count; only the palette is written (`Rooms.react/3`, 20 per 10 s).
- **Bans and mute.** `PubkyRooms.Rooms.Ban` markers on the creator's homeserver only (`user == creator` and `id == room_id` on the event); listed at bootstrap (one small GET per marker for the reason), applied live (the reason is read a moment later, `{:ban_reason, …}`). A banned author's messages leave the table (`{:message_deleted}` each), their reactions leave every row, their events are ignored, and paging forgets their entries; `del` restores them with a backfill. Banned members stay in `members` (their join marker is theirs) but are hidden from the members card except in the creator's "Removed by you" list. Mute is `RoomLive`-local (`muted` MapSet, this tab only): the window is re-streamed without the author, incoming messages and typing from them are skipped. Nothing is written for a mute.
- **Settings and directory.** `Rooms.update_room/4` overwrites the definition (20 per hour) and `close_room/3` deletes it; `/r/:c/:id/settings` is a dialog for the creator (others are patched back). `Directory.public_rooms/1` (visibility public, most recent activity then member count) feeds the lobby's "Public rooms" for everyone; the lobby debounces directory reloads (500 ms) because every message bumps a room's activity.
- **Tags and Nexus.** `PubkyRooms.Tags.Tag` implements pubky-app-specs `PubkyAppTag` (`Ids.crockford/1` for the 26-char hash id). The directory indexes tags on rooms (`:room_tags` bag, `:room_tag_ids` for deletions, DETS) from own writes, `pubky:all` events (one GET per tag file, verified against its id) and sign-in sync of `tags/`; `tags_of/1`, `own_tags/2`, `tagged_by?/3`, `rooms_tagged/1`, `popular_tags/1`. Public rooms get `room` + up to 4 creator labels at creation; unlisting deletes the creator's tags, relisting writes `room` again, closing deletes them. Any signed-in user tags/untags a room from its header (20 per hour, ≤ 10 own labels per room). `PubkyRooms.Nexus` is read-only and optional (`NEXUS_URL`): the directory polls `/v0/stream/resources?app=pubky-rooms` (timeline + taggers_count) every `nexus_sync_ms` and `by-uri` per room opened (throttled 5 min), stores tagger *counts* in memory (`:room_nexus_tags`, max with local counts) and fetches unknown rooms from their creator's homeserver. "Tagged by people you follow" (`viewer_id`) is not built (needs Pubky App integration, M8).
- **Text rendering.** `PubkyRoomsWeb.Linkify` builds the message HTML by hand (escaped text segments, `http(s)` anchors with `rel="noopener noreferrer nofollow ugc"`, trailing punctuation outside the link, `pubky://` left as text) so no whitespace is added inside the `white-space: pre-wrap` paragraph.
- **Presence meta** is now `%{joined_at}` only.

## Implementation notes (finish phase, 2026-09-21)
- **Closed rooms are read-only archives.** Deleting the definition no longer removes the room from the directory: `Directory.close_room/1` (called by `Rooms.close_room/3`, by the `rooms/<id>` DEL event and by a `RoomServer` that finds the definition gone for a room the directory knew) stamps `%Room{closed_at}`, keeps the members, drops the Nexus counts and broadcasts `{:room_closed, %Room{}}`. `public_rooms/1`, `popular_tags/1` and the tag filter only see open public rooms; `rooms_of/1` returns closed rooms (created or joined) under `closed`, which the lobby shows to former members in a collapsed "Closed" group with a badge. `RoomServer` bootstraps an archive from the members' folders exactly like an open room (`bootstrap/3`), broadcasts `:ready` and reports `status: :closed` in the snapshot; a live close keeps the process (and subscriptions) alive so members' own edits and deletes still apply, and the idle timer stops it as usual. Every write in this app is gated on `status == :ready` (`RoomLive.can_write?/1`, settings dialog, save/close handlers); leaving stays possible because the marker is the member's own file and is how they drop an archive from their lobby. The creator writing `rooms/<id>` again reopens the room (`RoomServer.update_room/2` flips `:closed → :ready` and broadcasts `:ready`; viewers re-attach). Closed rooms with no activity (opening one touches it) for `closed_room_ttl_ms` (90 days) are forgotten by an hourly sweep (`Directory.sweep_closed/1`). Rows written before `closed_at` existed are normalised when DETS is loaded.
- **Exact polling.** `RoomServer.poll_async/2` runs `fetch_history/4` in `:exact` mode: `list_until_known/4` pages a polled member's folder (newest first, `bootstrap_per_member` per page, ≤ 40 pages) until a page holds an id the room already knows (table or unfetched leftovers) or the folder ends, and every new entry is fetched (no `bootstrap_messages` cap, which would otherwise leave newer-than-boundary gaps that paging would prepend out of order). The result `{:poll_result, members, since, history, listed}` also carries every id listed per member: a confirmed message with `msg_id < since` (poll start minus one `member_poll_ms`, so a message a polled member wrote on this node moments ago is never misjudged) and `>=` the oldest listed id that is missing from the listing is removed as deleted; stale leftover entries are dropped too. Because paging stops at the first known id, that range is the member's newest page unless they wrote more; deeper deletions and all edits by polled members (listings carry no hashes) wait for the next bootstrap.
- **Persisted mutes.** `PubkyRooms.Mutes` (supervised, ETS `:mutes_cache`) holds a signed-in viewer's two mute lists: Rooms markers at `/pub/pubky-rooms/mutes/<z32>` (`mute/3` writes `{"v":1,"created_at"}`, 20 per hour; `unmute/3` deletes; bodies are never read) and Pubky App's `/pub/pubky.app/mutes/<z32>`, honored read-only (no capability there; the member row says "Muted in Pubky App" and offers no toggle). Lists are read on first use with a 5 s cap (two listings, deduplicated per user, `mutes_ttl_ms` 15 min so Pubky App changes show up), updated at once from Rooms mute events on `pubky:all`, and announced as `{:mutes_updated, z32}` on `mutes:<z32>`. `RoomLive.load_mutes/1` runs before the history is streamed (no flash of muted content) and `{:mutes_updated}` re-streams the window, so a mute made in another tab or on another device applies everywhere. Mutes are optimistic in the UI; a failed write reverts with a flash. Both lists are public for now (like Pubky App's); a private directory comes with private rooms. detached per-room message cache and incremental first paint (no evidence of need at current scale: bootstrap is members + newest-K, paging is on demand → M7 if measurements ask for it); members card and moderation controls are hidden below the `xl` breakpoint (mobile members sheet → M7 polish).

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
Creator ban/unban via ban markers (RoomServer hides messages; banned user's composer disabled); local mute (session-local); content 2000 / topic 280 / name 64; per-sid limits: messages 5/5 s, reactions 20/10 s, rooms 5/h, joins 20/h; per-IP login starts 10/min; bootstrap concurrency 8; `max_members_subscribed` 500 (documented v1 limit).

## PubSub topics
| topic | payloads |
|---|---|
| `pubky:user:<z32>`, `pubky:all` | `{:pubky_event, %Pubky.Events.Event{}}` |
| `room:<creator>/<room_id>` | `{:room_event, ref, ev}` with `ev` ∈ `:ready`, `{:error, :not_found}`, `:restarting`, `{:message_upserted, %Message{}}`, `{:message_deleted, key}`, `{:message_failed, key, reason}`, `{:member_joined, z32}`, `{:member_left, z32}`, `{:member_banned, z32}`, `{:member_unbanned, z32}`, `{:member_unreachable, z32}`, `{:room_updated, %Room{}}`, `:room_closed` |
| `room:<ref>:typing` | `{:typing, z32, boolean}` |
| `proxy:presence:room:<ref>`, `proxy:presence:lobby` | `{:presence, {:join | :leave, %{key, metas}}}` |
| `directory` | `{:directory_updated, %RoomSummary{}}`, `{:directory_removed, ref}` |
| `profiles` | `{:profile_updated, z32, %Profile{}}` |

`%Message{key, msg_id, author, room_ref, kind, content, reply_to, created_at, edited_at, state (:confirmed | :pending | :failed | :unconfirmed), fail_reason, uri, reactions}`.

## LiveViews and router
```elixir
pipeline :browser  # defaults + plug PubkyRoomsWeb.UserAuth, :fetch_current_user
live_session :default, on_mount: [{PubkyRoomsWeb.UserAuth, :mount_current_user}] do
  live "/", LobbyLive, :index
  live "/rooms/new", LobbyLive, :new
  live "/r/:creator/:room_id", RoomLive, :show
  live "/login", AuthLive, :index
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
  bootstrap_per_member: 50, page_size: 50, max_members_subscribed: 500,
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

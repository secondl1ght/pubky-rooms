# Backlog (follow-ups awaiting triage)

Maintainers' list of every open follow-up, collected from the design backlog table and the findings log (both now in `history/`) when the repository went public. Rows are triaged here (keep, merge, drop; priority; when) and then become GitHub issues; once an issue exists the row is replaced by its link. A follow-up that is neither here nor an issue does not exist.

Columns: **Area** is the label the issue would get; **Source** says where the item came from (the plan's milestone, a review, a QA run, a decision date); **Triage** stays empty until a maintainer fills it in (`issue #n`, `dropped: reason`, `merged into …`).

Done since the lists were written and therefore not here: avatar image ids (fixed 2026-10-01, `a098344`), membership rows for unconfirmed rooms (fixed 2026-09-30, `20a724f`), the static Open Graph image and per-page titles, the seeded demo rooms. Settled decisions (a retry keeps the message id, the pending clock stays, the hooks stay for launch) are recorded in `history/findings.md` and are not follow-ups.

## Pubky App integration (plan milestone M8)

| Item | Area | Source | Triage |
|---|---|---|---|
| Rooms summary API: `GET /api/rooms` and `/api/rooms/featured` for Pubky App, with CORS for those routes | `pubky-app` | plan M8 | |
| Back link (`?from=pubky.app`) and "share to Pubky App" from a room | `pubky-app` | plan M8 | |
| The Pubky App side: routes, nav items, a `/rooms` page, a Nexus resources service, runtime config (lives in the pubky-app repository; an upstream PR once Rooms is accepted into the ecosystem) | `pubky-app` | plan M8 | |
| Nexus "tagged by people you follow" (`viewer_id` on resource and tag queries) and Nexus taggers shown as people | `pubky-app` | plan M8 | |

## Product

| Item | Area | Source | Triage |
|---|---|---|---|
| Emoji picker: one component for the composer (desktop has no native emoji keyboard), reactions (any emoji instead of the fixed palette of named keys) and the tag input (emoji tags, Pubky App parity) | `enhancement` | idea 2026-09-22; deferred past launch | |
| Fallback avatars as a facehash port: a deterministic static SVG face (hash → one of the six signal colours, eye shapes and positions, the initial as the mouth) seeded like Pubky App so a person gets the same face in both apps; about two hours with tests | `enhancement`, `design` | idea 2026-09-22 | |
| Room icons chosen by the owner: a new field in the room file (spec mirror row, validation, the write path), with its own review | `enhancement` | polish list 2026-09-30 | |
| Lobby layout options: the room cards are large and the directory gets long even with the tag filter | `design` | polish list 2026-09-30; wants designer feedback | |
| Signed-out landing page with the designer's visuals (see pubky.app) | `design` | polish list 2026-09-30; before the public launch | |
| Notifications. Tier 1: the browser Notification API for mentions and replies while a tab is open (small). Tier 2: Web Push while the app is closed (VAPID keys, `web_push_encryption`, a per-browser subscription that needs private storage or a server-side store, the server following rooms nobody has open); the service worker leaves room for a push handler | `enhancement` | idea 2026-09-22 | |
| "Download this conversation": the loaded window plus the member list as JSON or Markdown; a full streamed export of a large room only on request (one GET per message, bandwidth-throttled by homeservers) | `enhancement` | idea 2026-09-21 | |
| "Continue this room on my homeserver": a member forks a closed (or any) room by writing a new definition that references the old room URI; the room server merges the old ref's history read-only with new messages under the new ref and members re-join the new ref | `idea` | idea 2026-09-21 | |
| Message search (jumping to a quoted message outside the loaded window is done; search was kept out of scope for launch) | `enhancement` | plan M7 | |
| Per-room Open Graph image carrying the room name (server-side PNG through libvips via `Image`, or a headless browser, plus a cache); the static brand image and per-page titles are done | `enhancement` | decision 2026-09-29 | |

## Protocol and credible exit

| Item | Area | Source | Triage |
|---|---|---|---|
| Publish the on-homeserver contract as a spec (paths, JSON shapes, limits, validation rules, ban and tag semantics, ids) so other clients can interoperate; today it lives in `docs/notes/rooms-app-design.md`. **Now phase 1 of the chat unification plan** ("public rooms v1" in pubky-chat spec v3, with vectors that `pubky_ex` runs in CI); drafted in this repo first, moved into spec v3 when it opens | `documentation` | plan M7; chat plan C1, 2026-10-02 | |
| Member list discoverable without a Rooms node: (a) the creator's live session writes a `members.json` snapshot to their homeserver when membership changes while they are online (no stored grants, ADR 0005 unchanged, the snapshot may be stale, join markers stay the source of truth), or (b) joining also writes a `member`-labelled universal tag on the room so Nexus's taggers endpoint answers "who is in this room" without a Rooms server. Today's documented v1 limitation: a joiner nobody on this node follows stays unknown until they sign in here. Decide with the spec | `idea` | QA question 2026-09-22 | |
| Private rooms as MLS groups under `/pub/chat/v1/` (chat plan E4), in the hybrid shape: the server keeps the directory, presence, typing, live fan-out, paging, the UI and its write grant; the browser holds only the device key and the MLS state through the shared WASM library. Requirements for the spec: join from an invite link while the creator is offline; server-mediated device attestation (browser-generated key shown in Ring, the page verifies the attested key). Waits on the MLS library (C3) and the `att` claim (K5) | `enhancement` | chat plan E4 | |
| Owner-only data under `/priv/` now (usable before the private-data redesign): move the viewer's mute markers, and add read cursors and drafts, to `/priv/` paths following social specs v1 (`/priv/social/v1/mutes/`); `/priv/` is authorization, not encryption, so nothing shared goes there | `enhancement` | social specs #142 | |

## Scale and robustness

| Item | Area | Source | Triage |
|---|---|---|---|
| `Subscriptions.capture_cursor/1` reuses a stored cursor however old, so a member re-followed after days replays every event since; capture "now" when the user has no live stream and keep the stored cursor for reconnects only | `scale` | review 2026-09-30 | |
| A warm room's ETS table grows without bound while someone stays in it (every live and paged message stays); trim rows below the paging boundary past a configured size; watch `pubky_rooms.room.messages` on staging first | `scale` | review 2026-09-30 | |
| Resolution tasks in `Subscriptions` have no concurrency cap: a 500-member room opens about 1,000 `latest_cursor` requests on the 50-connection pool (jitter and growing retries exist); add a small in-flight queue (about 16) before big rooms | `scale` | review 2026-09-30 | |
| Async bootstrap: `RoomServer` answers `attach`, `snapshot` and `register_pending` with `:bootstrapping` instead of blocking its mailbox for the whole backfill (today the page waits for the call timeout, then `:ready` attaches it) | `scale` | review 2026-09-30 | |
| Sidebar members list: a rendered cap with a count for very large rooms (thousands of members; the layout is bounded, the DOM is not) | `scale` | polish list 2026-09-30 | |
| Detached per-room message cache (re-bootstrap "since last id") and incremental first paint for huge rooms; deferred for lack of evidence (bootstrap is members plus newest-K, paging on demand); revisit with telemetry | `scale` | plan M7 | |
| Pubky App profile changes are only noticed at the cache TTL (streams carry `/pub/pubky-rooms/` only); consider a second stream path `/pub/pubky.app/profile.json` for signed-in users | `enhancement` | plan M7 | |
| Authenticated reads with `PUBKY_SERVICE_CREDENTIAL` (operator whitelist first, a service account if the bandwidth throttle bites); deferred because the throttle only slows reads and the app degrades instead of failing | `operations` | decision 2026-09-21 | |

## Security

| Item | Area | Source | Triage |
|---|---|---|---|
| Pin the homeserver connection to the vetted address so a DNS rebind between resolve and connect cannot slip through (a Finch/Mint transport option). The host policy already resolves the name, refuses private addresses and numeric-looking names (`127.1`, `0x7f.1`), never follows redirects and ignores the plain-HTTP SvcParam | `security` | security review 2026-09-30 (narrowed) | |
| A periodic bearer check for idle tabs: a revoked grant is noticed on the next write, so an idle tab looks signed in until then | `security` | review decisions 2026-09-30 | |
| Full unscoped code and security review of the whole repository (the pre-launch reviews were scoped by file lists to bound their cost) | `security` | decision 2026-09-29; after launch | |

## Operations and CI

| Item | Area | Source | Triage |
|---|---|---|---|
| Expose the deployed commit: a `GIT_SHA` build argument in the Dockerfile passed by the deploy workflow and read in `runtime.exs`, shown in `/healthz` (`"commit": "…"`) and as `<meta name="build">` in the page head; the post-deploy smoke then asserts the deployed commit is the one CI tested. Today: match `fly releases` times against the deploy runs | `operations`, `ci` | maintainer 2026-10-01 | |
| CI shows "8/9" on every push run: the `deploy_after_dispatch` job is skipped by design (it runs only when CI was started by hand or by the baselines workflow, whose runs produce no `workflow_run` event). Make the skip read as intended: a job name such as "dispatch the deploy (hand-started runs only)", or move the dispatch into the baselines workflow after a `gh run watch` of the CI run it starts | `ci` | maintainer 2026-10-01 | |
| Hooks versus LiveView bindings, a simplify pass: the composer's typing throttle could be `phx-keyup` + `phx-throttle="2000"` (about 15 lines of JS fewer); part of the tag input could move to `phx-keydown`/`phx-blur` with a server-side highlight (180 → about 70 lines, but the behaviour splits and arrow highlighting gains a round trip). Decided to keep the hooks for launch | `enhancement` | decision 2026-09-29 | |
| One intermittent app-suite failure (about one local run in nine on 2026-10-01) was never captured; the two flaky tests found before were assertions racing a confirmed state. If it shows again, record the test name and the assertion | `bug`, `ci` | maintainer 2026-10-01 | |

## Chat unification (items from the ecosystem's chat unification plan, `BitcoinErrorLog/pubky-chat`)

| Item | Area | Source | Triage |
|---|---|---|---|
| Namespace rename `/pub/pubky-rooms/` → `/pub/rooms/v1/` (app-neutral, versioned like social specs v1): grant scope, stream filter, directory, spec mirror, docs, tests, the demo rooms re-seeded; every staging user signs in again. **Blocked** on Nexus confirming universal tags under versioned roots (`/pub/<app>/v1/tags/`); do it together with every other breaking change, before production | `enhancement` | chat plan, phase 1 | |
| Social specs v1 migration (`pubky/pubky-app-specs#142`): profiles, tags and mutes move from `/pub/pubky.app/` to `/pub/social/v1/`; Rooms reads profiles and mutes and writes tags, so it follows the move (read both paths during the transition); refresh the spec-mirror fixtures. Timing is core's; a couple of months out | `enhancement` | chat plan P23; specs #142 | |
| Member-list discovery through the chat plan's change-feed index (L3) as a third source beside the two options above and the local directory; the client side once the index protocol exists | `enhancement` | chat plan, phase 2 | |
| Prototype the change-feed index in Elixir on `pubky_ex` once its protocol is written (reuses the stream pool, cursors, backoff and 429 handling); scale beyond per-user streams needs core's H9 | `idea` | chat plan I1 | |
| Staging-facts note for the index protocol: the 429 on the event-stream connect, the per-connection user cap (50 per stream, 100 streams), cursor behaviour across restarts and the 7-day cursor sweep; written from `docs/operations.md` and the history findings | `documentation` | chat plan I1 | |
| Pubky App directory page that opens rooms in Rooms (the M8 rows above) as the alternative to pubky.app rendering rooms natively; if native rendering comes later it takes its live feed from a Rooms node | `pubky-app` | chat plan, phase 1 | |
| Report-to-creator as a private message sent from Rooms once Rooms has private messaging; bans stay public; no interim button | `enhancement` | chat plan, phase 3 | |

## Upstream and QA

| Item | Area | Source | Triage |
|---|---|---|---|
| Homeserver rate limit on the event-stream connect: one 429 with `Retry-After: 1` per cold bootstrap from a node's address (retried, one warning logged). A node is one IP for all its rooms, so a strict per-IP limit on `/events-stream` would throttle a busy node harder than a browser; raise with the homeserver team if Rooms joins the product lineup | `upstream` | staging run 2026-09-30; decision 2026-10-01 | |
| Revoke on a real device: the checklist's §13 revoke row is blocked until Ring ships a revoke UI (checked with the Ring team 2026-09-30); the revoked and expired paths are unit-tested | `upstream`, `qa` | checklist | |
| Phone pass on iOS (Android done 2026-09-30): the touch icon and status-bar colour, Install, the installed window, Ring's deep link from it | `qa` | launch checklist | |

# Manual QA checklist

The browser-driven pass nothing automated covers yet: the LiveView client
(locks, patches, focus), layout, the PWA, and the whole flow across two
identities on a real homeserver. Run it before every deploy and after any
change to sessions, the room server, the hooks or the shell. The full pass
takes about 90 minutes; the items marked **smoke** take about 15 and are the
minimum before a deploy.

**Living document.** The list is a starting point, not a script: whoever runs it
adds the check they wish had been there (in the same commit as the fix, when a
finding leads to one), removes checks for features that no longer exist, and
rewrites steps that have drifted from the UI. Anything worth verifying that is
not on the list yet belongs on it, so the pass gets more complete each time
rather than more stale. Findings are recorded as described in `README.md`.

## Setup

- Testnet up: `docker compose up homeserver -d` in a `pubky-docker` checkout; `curl localhost:6286/info` answers. After a reboot the in-memory PKARR relay has forgotten every identity: rooms from before render as closed archives with "live updates unavailable" (expected, not a bug). Make fresh identities.
- Dev server (`mix phx.server`, port 4000) and the Ring Simulator (`npm run dev -- --port 5173` in a `pubky-ring-simulator` checkout). When the pass is driven from the Claude desktop app, both are entries in the gitignored `.claude/launch.json` (`pubky-rooms`, `ring-simulator`).
- Identities: **A** (creator) in one browser, **B** (member) in a second browser or profile with its own cookies (for example the Claude desktop app's browser pane and a connected Chrome); both via Simulator → Add pubky → Shortcut → paste the sign-in link. **anon** is a private window. Simulator identities vanish on reload; Rooms cookies survive.
- Tools: DevTools console (CSP violations, JS errors) and network tab open; `liveSocket.enableLatencySim(400)` for race checks, `disableLatencySim()` after; `resize_window`/DevTools at 375 px for **phone** items.
- Automation notes: `data-confirm` buttons need `window.confirm = () => true`; hidden tabs never run `requestAnimationFrame`, so check `document.title` in a visible tab; an embedded browser pane's Return key may not reach the page (the Claude desktop app's does not): dispatch a `KeyboardEvent` or call `form.requestSubmit()`.
- Screenshots for review: a throwaway Playwright script (the package is in `pubky_rooms/assets/node_modules`, the browser comes from `npx playwright install chromium`) can drive the dev server headless as an anonymous viewer, open sheets, trigger the connection toast (`liveSocket.disconnect()`) and save PNGs; states only the fake homeserver can produce (a member's history unreachable) come from a throwaway ExUnit test that writes `render(view)` into an HTML file with the CSS linked absolutely.
- A room this node has never seen, or a big room for paging: `cd pubky_rooms && mix run --no-start scripts/headless_room.exs [count]` writes one straight to the homeserver from a fresh headless identity and prints its URL (the first visit is the only "unknown" one; afterwards the room is warm). A member nobody follows stays invisible to the directory until they sign in here.

Legend: **smoke** = minimum pre-deploy set · **A+B** = needs both identities · **anon** = private window · **phone** = 375 px wide.

## 1. Health and shell

- [ ] **smoke** `GET /healthz` → 200 JSON with `status`, `rooms`, `streams`, `stream_pool`; nothing identifying in it.
- [ ] **smoke** Lobby, room, `/login`, `/me`: console has no errors and no CSP violations after a full navigation of each.
- [ ] `/r/not/valid` → "That room link is not valid." flash, back on the lobby; a well-formed link to a room that does not exist → the styled "Room not found" page; a 404 page for `/nope` in the app's styling ("Page not found · Pubky Rooms").
- [ ] Header: logo alignment, the three round buttons hover like Pubky App (`bg-accent`), tooltips, active state on the current page; avatar has no hover ring.
- [ ] Toasts: info/success dismiss after 5 s, warnings (rate limits, "Slow down — try again in N s.", amber) after 8 s, pause on hover, error stays; text centred with the icon; close button centred. **phone**: full width inside the 16 px gutters, above the tab bar.

## 2. Signed out (anon)

- [ ] **smoke** Lobby: hero copy ("Group chat where every message is yours to keep…"), Sign in CTA (full width below `sm`), Directory with cards, How it works as the right column from `xl` and as a ruled footer section below it; no "Your rooms".
- [ ] Sidebar: Lobby / Open a room / Directory, the live dot pulsing next to "N people online", Tags chips; clicking a tag filters the Directory, the chip outlines, `?tag=` in the URL, the empty state "Nothing tagged x" for an unknown tag.
- [ ] Open a room while signed out → redirected to `/login?return_to=/rooms/new` with "Sign in to open a room."
- [ ] Room page read-only: messages, header, tags (no "+"), members card without actions, composer replaced by a sign-in prompt; you count as an anonymous viewer (eye icon on the lobby card, "· N anonymous" in the header for signed-in viewers).
- [ ] `/login`: QR renders, "Open in Pubky Ring" carries a `pubkyauth://signin_grant` link with `caps=/pub/pubky-rooms/:rw`, Copy link works, the six trust points read correctly, the onboarding box; the code expires with a clear message ("This code expired. Generate a new one to try again.", after about 3 min 20 s on staging: the 2-minute deadline plus the relay's last long-poll) and New code issues a fresh secret.
- [ ] `/me` while signed out → `/login`.
- [ ] **phone** Lobby: header is back + logo only; tab bar Lobby / Open a room / Sign in pill; online line and scrolling Tags row above the Directory heading; How it works closes the page.

## 3. Sign-in and session

- [ ] **smoke** Simulator approval lands you back on the page you came from (`return_to`) with the avatar in the header; the Simulator shows "Logged in · 1 permission".
- [ ] Restart the dev server: the tab reconnects and you are still signed in (the credential lives in the cookie; the server holds nothing on disk).
- [ ] Sign out from `/me`: back on the lobby signed out; the homeserver session is gone (a second sign-out or a write in another tab fails cleanly).
- [ ] Revoke the grant in the Simulator (or sign out there) then act in Rooms → a "signed out on the homeserver" style error, not a crash; signing in again works.
- [ ] Sign-in start limit: the 21st connected `/login` load within a minute shows "Too many sign-in attempts. Please wait a minute." with no code (the limit counts connected mounts, so `curl` never hits it); recovers after the window.
- [ ] Two tabs, same identity: presence shows one person; typing in one is **not** shown in the other (you never see yourself typing); sign-out in one signs out the other on its next action (same browser: the cookie is shared; a second sign-in in another browser is a separate homeserver session and stays valid).

## 4. Lobby, signed in

- [ ] **smoke** Your rooms / Joined / Directory / Closed groups appear only when non-empty; own and joined rooms are not repeated in the Directory; with a tag filter only the filtered Directory shows.
- [ ] Cards: name, topic, member count, online count, eye icon with anonymous viewers, relative time, tag chips (filtered tag first, three shown, `+n`), "unlisted" badge, closed badge in the Closed group.
- [ ] Live: a message sent in a room (by B) bumps the card's activity within a second; a room B opens appears without reload; online counts follow presence.
- [ ] Empty state after a fresh sign-in: "No rooms yet" with Open a room; Directory empty state "Open the first one."
- [ ] How it works is hidden once signed in (desktop column and phone footer).

## 5. Open a room (dialog)

- [ ] **smoke** Name + Listed + one tag → "Open room" → toast "Room opened. Copy the link to invite people.", you are on the room page as creator and member, the room is in Your rooms and the Directory, the homeserver has `rooms/<id>`, `members/<you>/<id>` and `tags/<hash>` files for `room` and your label (`curl localhost:6286/storage/<z32>/pub/pubky-rooms/`).
- [ ] Validation sentences: empty name → "Give the room a name of 1 to 64 characters."; 65 chars blocked by `maxlength`; topic 281 blocked; visibility cards select on click and via keyboard (arrows, space).
- [ ] Tags input: "+" opens the field focused; typing "Bit Coin,X" becomes "bitcoinx"; Enter adds a chip in the label's colour; suggestions from known tags, arrows + Enter pick one; Backspace on empty removes the last chip; Escape clears then folds; blur on an empty field folds; the fixed `room` chip has no x and typing `room` adds nothing; the fifth tag turns the field read-only with a red "limit reached" that stays until you leave; remove one and the field is live again.
- [ ] Two tags entered quickly (Enter, Enter within ~150 ms) with `enableLatencySim(400)`: both chips stay, none turn into an empty gap. (LiveView lock race, hooks are unit-tested but this needs the real client.)
- [ ] Switch to Unlisted: the tags block disappears and the chips are dropped; back to Listed starts empty; an unlisted room gets no tag files and no "unlisted" tag in the directory, only the badge.
- [ ] Cancel, Escape and clicking outside close the dialog and patch back to `/`; reopening starts clean.
- [ ] Sixth room within an hour → "Slow down" on submit, nothing written.
- [ ] **phone** The dialog is a bottom sheet; cards stack; the tag field fits.

## 6. Room, as owner (A)

- [ ] **smoke** Send: Enter sends, Shift+Enter breaks a line, the row appears pending and flips to the check mark when the SSE event returns; the composer clears and keeps focus; the footer names the storage path.
- [ ] Composer: grows to eight lines then scrolls; 2000-character cap enforced; blank Enter sends nothing; typing shows "… is typing" to B within 2 s and clears 4 s after you stop or on send/blur.
- [ ] Six messages within 5 s → "Slow down — try again in N s" and the sixth is not written.
- [ ] Edit: the composer shows the text with the caret at the end, "editing" state, Escape or Cancel restores (Escape since `ffd074d`), save replaces the row (edited marker), B sees the edit live.
- [ ] Delete: confirm dialog; the row leaves for everyone; the file is gone from the homeserver.
- [ ] Reply: quote block above the composer with a 140-character preview, Cancel clears it, the sent row shows the quote; clicking the quote scrolls to the original and flashes it, also when the original is pages back (it loads until found) or gone ("That message is no longer available.").
- [ ] Reactions: hover/long-press menu offers 👍 ❤️ 😂 👀 🔥 😢; toggling adds/removes your reactor, counts merge across users, B's reactions arrive live; 21 in 10 s → "Slow down".
- [ ] Failed send: the row shows "Not stored: …" with Retry and Discard (only the sender sees it); Retry fails again in place while the cause persists, then stores the message at its original place for everyone; Discard drops it, nothing to delete anywhere. Recipe on the testnet: `curl -X PATCH -H 'X-Admin-Password: admin' -H 'Content-Type: application/json' -d '{"storage_quota_mb": 0}' http://localhost:6288/users/<pubkey>/quota` makes every write from that identity fail with "out of storage" (streams stay up); `-d '{"storage_quota_mb": null}'` lifts it. Stopping the homeserver container works too but takes the event streams down with it.
- [ ] **smoke** First paint (a direct link visit and a hard refresh are the same path). Warm room (someone is in it): complete from the first paint (title, header, tags with "+", members, anonymous count, messages, your composer or Join button), nothing flashes. Cold room (restart the dev server, then open a room link directly): header, members and your own state at once, "Loading messages…" for a moment. Never-seen room (setup script): the single page loader, then the room. A cold archive shows its closed badge at once. Automated: the dead-render test covers creator, non-member, member, anonymous, warm, muted author, archive and unknown; this item is the eyes-on check.
- [ ] Header: name, topic, live dot + "N online · M anonymous", copy-link button confirms with a check mark and "Copied" tooltip, settings gear (creator only), tag row with "+"; your own chips are outlined and remove on click ("Remove your tag"), another user's chip offers to add yours ("Tag this room too").
- [ ] Tags from the header: add (chip appears for everyone, file on your homeserver), clicking your own chip removes it; a tag another user added is not yours to remove; an 11th own label or the 21st tag change within an hour → "Slow down".
- [ ] Members: card from `xl`, sheet below (`open_members`/close); owner marked, online dots, B appears when joining and greys out when leaving; hover actions (mute, remove) on desktop, always visible on phone.
- [ ] Remove (ban) B with a reason ≤ 140 chars: owner "Member removed. Their messages are hidden while the ban is in place."; B toast "You have been removed from this room." + notice with the reason as a red badge, no Leave button; everyone else "B was removed by the owner; their messages are hidden." and a "Removed by the owner" list (reason badge, no Restore); restore: B "You were restored by the owner; your messages are back.", others "B was restored by the owner; their messages are back."; B's rows leave, their reactions leave every row, B's new messages are ignored, B sees the read-only composer; "Removed by you" list shows B; Restore → "Member restored." and B's history comes back.
- [ ] Mute B (yours only): B's rows and typing vanish in your view only; reload and a second tab of yours agree (persisted marker); Unmute restores. Muting is invisible to B.
- [ ] Settings: rename, topic, Listed → Unlisted (own tags deleted on the homeserver, badge appears, gone from the Directory), Unlisted → Listed (`room` tag written again); "Room updated."; 21 updates in an hour → "Slow down".
- [ ] Close room: confirm → "Room closed. Members' messages stay on their own homeservers."; the page becomes a read-only archive for everyone (B gets "The creator closed this room."), the room moves to the Closed group for members, disappears from the Directory and popular tags, tag files are deleted. Reopening has no UI (a client writing `rooms/<id>` again reopens it; covered by tests).
- [ ] Leave as a plain member still works on an archive (it drops the archive from your lobby).
- [ ] **phone** Room page: header wraps, composer above the tab bar, members sheet slides up, reaction menu reachable by touch.

## 7. Room, as member and viewer (A+B)

- [ ] **smoke** B opens A's link: history in order with names/avatars, Join → "You joined the room.", B appears in members and in A's presence; B sends and A sees it live with the check mark on B's side only.
- [ ] Leave → confirm ("Leave the room? Your messages leave with you…"); then B: "You left the room. Your messages went with you; join again to bring them back."; everyone else: "B left the room; their messages went with them."; B's rows leave for everyone (files still on B's homeserver), join marker gone, B can still read (public) but cannot write; Join again brings B's rows back; 21 joins in an hour → "Slow down".
- [ ] Names: a Pubky App profile name wins over a Rooms nickname over the truncated key; changing the nickname on `/me` updates rooms within the profile TTL (or immediately for your own tabs).
- [ ] Pubky App mutes (mainnet only): a user muted in Pubky App is hidden here read-only. Testnet: skip, unit-tested.
- [ ] anon in the same room: counted in "anonymous", never listed, sees everything live.

## 8. History and paging
- [ ] Paging fixture: `cd pubky_rooms && mix run --no-start scripts/headless_room.exs 300` writes a 300-message room; the first visit shows the newest page, "Load earlier messages" sits at the top of the list, scrolling up auto-loads 50 at a time with the spinner visible at the top, the reader's place is kept, and the button disappears at message 1.

- [ ] Room with > 100 messages: the newest 100 load; scrolling to the top loads older pages, keeps the reader's place, and keeps paging short pages; the top button appears when a page is empty (a member's homeserver down) and pressing it retries; no request loop in the network tab.
- [ ] "Earlier messages could not be loaded right now." when a member's homeserver is unreachable; Retry history works after it returns.
- [ ] Restart the dev server with the room open: the page reconnects, the room re-bootstraps from the homeservers and shows the same messages (nothing durable lives in the app).

## 9. Degraded states

- [ ] Member with a dead key (post-reboot identity): banner "Live updates from N members are unavailable", member marker, room still readable; an archive whose definition is gone shows as closed.
- [ ] Homeserver unreachable while browsing: a cold room shows "The owner's homeserver could not be reached. Try again later." (no button: the room server gives up after 30 s, the page re-attaches and bootstraps again, so it recovers by itself within about a minute of the homeserver returning), no crash. **Never `docker stop`/`restart` the testnet homeserver to simulate this**: its PKARR relay and file blobs live in the container, so a restart kills every identity and empties every file (the listing index survives, so rooms read as closed archives with no messages; 2026-09-30, learned the hard way). Use `docker pause homeserver` / `docker unpause homeserver` (untried) or a firewall rule on port 6286 instead.
- [ ] Rate-limited homeserver (`429`): one retry honouring `Retry-After`, then the member is marked unreachable with Retry.
- [ ] Over the live budget (`max_members_subscribed` lowered in config for the test): the notice "over the live-subscription budget" and polled members' messages arriving within a minute.
- [ ] No `NEXUS_URL` (testnet): the Directory still lists rooms this node saw; no errors logged.

## 10. Profile (`/me`)

- [ ] **smoke** Shows the key with a working copy button, the signed-in-with and access-granted facts, the name source, Sign out (secondary, right-aligned; full width on phone).
- [ ] Nickname: save (≤ 32, "Nickname saved to your homeserver."), clear ("Nickname removed."), 11 saves in 10 minutes → "Slow down"; the file lands at `/pub/pubky-rooms/profile.json`.
- [ ] Key that does not resolve (dead PKARR record): the page must not pretend the profile is empty (open item: `/me` says "No profile found yet" when the key does not resolve).

## 11. PWA and offline
The service worker is **never registered in development** (`app.js`: asset names are not content-hashed there); the caching and offline items can only be checked on a production build, so they are run on staging (section 13). The manifest and head tags can be checked anywhere.

- [ ] `/manifest.webmanifest` valid (name, icons incl. maskable, `display: standalone`, `#05050A` colours); install prompt available in Chrome; the installed app opens on the lobby.
- [ ] Service worker: static assets served from cache on reload; HTML is never cached (edit a page, reload, see the change); with the network offline, navigating shows `/offline.html`; the websocket is untouched.
- [ ] iOS: `apple-touch-icon` and theme colour present in `<head>`.

## 12. Operations

- [ ] Logs during the whole pass carry no public keys, IPs or message content at info and above (grep the dev log for a z32 you used).
- [ ] `Subscriptions.info/0` and `/healthz` agree on streams; the capacity warning fires when the pool crosses 80 % (lower `PUBKY_STREAM_POOL_SIZE` to test).
- [ ] `priv/data/directory.dets` survives a restart; rooms, memberships and tags are still listed.

## 13. Real infrastructure (staging, before production) — the dependency unknowns
Never exercised on the testnet; each one is verified on the staging deploy before anyone else gets the link.
- [x] **smoke** Sign in with the real Pubky Ring (grant auth; the APK is shared with the team until Ring ships it): the deep link opens Ring, the grant lands, `/me` shows the identity. (2026-09-30: two throwaway staging identities scanned with the real Ring; `/me` shows the names, "Signed in with Pubky Ring", `/pub/pubky-rooms/:rw`; the deep link on the phone itself was verified in the Android pass.)
- [x] **smoke** A real write to `homeserver.staging.pubky.app` through the grant session (open a room, send a message): the staging homeserver advertises `path-addressed-storage`, so path addressing is used and the message confirms. (2026-09-30 night: room with topic and two tags, stored check in ~0.4 s; the room, member, message and tag files read back from `/storage/<user>/pub/pubky-rooms/…` with curl.) (On production, a homeserver without the feature makes the library fall back to legacy addressing, `/pub/...` + `pubky-host`, automatically; check the log line at debug if that ever matters.)
- [x] **smoke** Live updates on mainnet: a second identity sees the message live (`/events-stream`), and a reconnect resumes from the cursor without duplicates. (2026-09-30 night: second identity and anonymous viewer see a message in ~0.8 s; 200 messages from two identities, every view ordered without duplicates; the stream connect gets a 429 from Fly's address during a cold bootstrap — was fatal, now retried after `Retry-After: 1`, see findings.)
- [x] PKARR resolution on mainnet: `pkarr.pubky.org` is tried first (`pkarr.pubky.app` allows about 10 requests per minute per IP), results are cached; a room whose members were never seen resolves them all without errors in the logs. (2026-09-30 night: a dozen cold starts resolved both members every time, no resolver warnings.)
- [x] Anonymous read throttling from Fly's shared egress IP: a big room bootstraps (slowly is fine, errors are not). (2026-09-30 night: the 200-message room bootstraps cold in 3–6 s with no read errors at debug; only the event-stream connect is throttled, retried after 1 s.)
- [x] Behind Fly's proxy: `x-forwarded-for` has the shape `client, <fly address>` (verified 2026-09-30 on staging: two IPv4 entries, seen with a one-off telemetry probe attached over `fly ssh console --command "/app/bin/pubky_rooms rpc …"` and detached again, nothing logged), `check_origin` and the URL host are the Fly hostname (websocket connected from a browser), `/healthz` passes on the platform check and from outside.
- [x] A redeploy replaces the machine: open tabs reconnect and re-mount on their own (LiveView's reconnect), nobody has to reload; the volume stays attached. (2026-09-30 night: three redeploys and a `fly machine restart` with a signed-in tab and an anonymous tab open — reconnected in 5–15 s, no navigation, a message right after confirmed in under a second and arrived live.)
- [x] Link previews (2026-10-01: pasted into a chat app, rendered as expected): paste the lobby link and a room link (with a topic) into a preview checker or a chat app — the title is the room name with "· Pubky Rooms", the description is the topic (the tagline for the lobby), the 1200×630 image loads over https from the digested path. (Tags and the image over https verified with curl on staging 2026-09-30.)
- [ ] Revoke the Rooms grant in Ring while signed in: the next write (message, nickname, join, tag…) lands on the sign-in page with "Your session has expired. Please sign in again." and the browser is signed out (cookie dropped); an idle tab notices on its next write, not before. **Blocked until Ring ships a revoke UI (checked with the Ring team, 2026-09-30); the revoked/expired paths are unit-tested (`session_store_test`, `user_auth`, the LiveViews' revoked-grant redirects) — run this row when the UI lands.**
- [x] Nexus (`NEXUS_URL=https://nexus.pubky.app`) contributes tag counts; with Nexus unreachable the app still works. (2026-09-30 night: staging Nexus indexes a new room and its tags within two seconds; the app read **zero** tags because `by-uri` wraps the fields as `resource` — fixed, verified on the node. Unreachable-Nexus is unit-tested.)
- [x] DETS volume survives a restart and a redeploy (rooms and tags still listed). (2026-09-30 night: a dozen restarts and three redeploys; the room stays in the directory with its tags.)
- [ ] PWA on the production build (the worker never registers in dev; on staging headless Chromium registers it and caches five assets after a reload, 2026-09-30 — embedded browser panes may refuse service workers, use a real browser; 2026-09-30 night: current bundle after three redeploys, HTML never from the worker cache, offline page, websocket untouched — all verified headless, see the findings log; **left for the phone: Install, the installed window, Ring's deep link from it, iOS icon/status bar**): Chrome offers Install and the installed app opens on the lobby; static assets come from the worker cache on reload while HTML never does (deploy a copy change, reload, see it); offline navigation shows `/offline.html`; the websocket is untouched; iOS shows the touch icon and theme colour. Can also be run earlier on a local production build on another port with its own `PUBKY_DATA_DIR` (~20 min) if staging is far off.
- [x] Before sharing the link: test rooms deleted, a few real rooms seeded, the directory reads well. (2026-10-01: test rooms closed, ten demo rooms opened by a maintainer's staging identity with tags and opening lines, the automatic `room` chip hidden on cards; the unlisted smoke room stays for the deploy workflow.)

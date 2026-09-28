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
rather than more stale. Findings go into `findings.md` per `README.md`. Record
each run in the table at the end.

## Setup

- Testnet up: `cd ~/CODE/pubky-docker && docker compose up homeserver -d`; `curl localhost:6286/info` answers. After a reboot the in-memory PKARR relay has forgotten every identity: rooms from before render as closed archives with "live updates unavailable" (expected, not a bug). Make fresh identities.
- Dev server (`pubky-rooms`, port 4000) and the Ring Simulator (`ring-simulator`, port 5173) from `.claude/launch.json`, or `mix phx.server` + `npm run dev` in `~/CODE/pubky-ring-simulator`.
- Identities: **A** (creator) in the in-app browser, **B** (member) in Chrome; both via Simulator → Add pubky → Shortcut → paste the sign-in link. **anon** is a private window. Simulator identities vanish on reload; Rooms cookies survive.
- Tools: DevTools console (CSP violations, JS errors) and network tab open; `liveSocket.enableLatencySim(400)` for race checks, `disableLatencySim()` after; `resize_window`/DevTools at 375 px for **phone** items.
- Automation notes: `data-confirm` buttons need `window.confirm = () => true`; hidden tabs never run `requestAnimationFrame`, so check `document.title` in a visible tab; the in-app browser's Return key does not reach the page (dispatch a `KeyboardEvent` or call `form.requestSubmit()`).
- A big room (paging): the pattern in `test/integration/app_testnet_test.exs` (`Pubky.Auth.LocalSigner` + `Pubky.Storage.put`) writes hundreds of messages headlessly; a member nobody follows stays invisible to the directory until they sign in here.

Legend: **smoke** = minimum pre-deploy set · **A+B** = needs both identities · **anon** = private window · **phone** = 375 px wide.

## 1. Health and shell

- [ ] **smoke** `GET /healthz` → 200 JSON with `status`, `rooms`, `streams`, `stream_pool`; nothing identifying in it.
- [ ] **smoke** Lobby, room, `/login`, `/me`: console has no errors and no CSP violations after a full navigation of each.
- [ ] `/r/not/valid` and a room id that does not exist → "That room link is not valid." flash, back on the lobby; a 404 page for `/nope` in the app's styling.
- [ ] Header: logo alignment, the three round buttons hover like Pubky App (`bg-accent`), tooltips, active state on the current page; avatar has no hover ring.
- [ ] Toasts: info/success dismiss after 5 s, pause on hover, error stays; text centred with the icon; close button centred. **phone**: full width inside the 16 px gutters, above the tab bar.

## 2. Signed out (anon)

- [ ] **smoke** Lobby: hero copy ("Group chat where every message is yours to keep…"), Sign in CTA (full width below `sm`), Directory with cards, How it works as the right column from `xl` and as a ruled footer section below it; no "Your rooms".
- [ ] Sidebar: Lobby / Open a room / Directory, the live dot pulsing next to "N people online", Tags chips; clicking a tag filters the Directory, the chip outlines, `?tag=` in the URL, the empty state "Nothing tagged x" for an unknown tag.
- [ ] Open a room while signed out → redirected to `/login?return_to=/rooms/new` with "Sign in to open a room."
- [ ] Room page read-only: messages, header, tags (no "+"), members card without actions, composer replaced by a sign-in prompt; you count as an anonymous viewer (eye icon on the lobby card, "· N anonymous" in the header for signed-in viewers).
- [ ] `/login`: QR renders, "Open in Pubky Ring" carries a `pubkyauth://signin_grant` link with `caps=/pub/pubky-rooms/:rw`, Copy link works, the six trust points read correctly, the onboarding box, "New code" issues a fresh secret; the code expires after 2 minutes with a clear message and New code recovers.
- [ ] `/me` while signed out → `/login`.
- [ ] **phone** Lobby: header is back + logo only; tab bar Lobby / Open a room / Sign in pill; online line and scrolling Tags row above the Directory heading; How it works closes the page.

## 3. Sign-in and session

- [ ] **smoke** Simulator approval lands you back on the page you came from (`return_to`) with the avatar in the header; the Simulator shows "Logged in · 1 permission".
- [ ] Restart the dev server: the tab reconnects and you are still signed in (the credential lives in the cookie; the server holds nothing on disk).
- [ ] Sign out from `/me`: back on the lobby signed out; the homeserver session is gone (a second sign-out or a write in another tab fails cleanly).
- [ ] Revoke the grant in the Simulator (or sign out there) then act in Rooms → a "signed out on the homeserver" style error, not a crash; signing in again works.
- [ ] Sign-in start limit: 21 `/login` loads within a minute → "Slow down" message, recovers after the window.
- [ ] Two tabs, same identity: presence shows one person, typing from one shows in the other's room, sign-out in one signs out the other on its next action.

## 4. Lobby, signed in

- [ ] **smoke** Your rooms / Joined / Directory / Closed groups appear only when non-empty; own and joined rooms are not repeated in the Directory; with a tag filter only the filtered Directory shows.
- [ ] Cards: name, topic, member count, online count, eye icon with anonymous viewers, relative time, tag chips (filtered tag first, three shown, `+n`), "unlisted" badge, closed badge in the Closed group.
- [ ] Live: a message sent in a room (by B) bumps the card's activity within a second; a room B opens appears without reload; online counts follow presence.
- [ ] Empty state after a fresh sign-in: "No rooms yet" with Open a room; Directory empty state "Open the first one."
- [ ] How it works is hidden once signed in (desktop column and phone footer).

## 5. Open a room (dialog)

- [ ] **smoke** Name + Listed + one tag → "Open room" → toast "Room opened. It lives on your homeserver.", you are on the room page as creator and member, the room is in Your rooms and the Directory, the homeserver has `rooms/<id>`, `members/<you>/<id>` and `tags/<hash>` files for `room` and your label (`curl localhost:6286/storage/<z32>/pub/pubky-rooms/`).
- [ ] Validation sentences: empty name → "Give the room a name of 1 to 64 characters."; 65 chars blocked by `maxlength`; topic 281 blocked; visibility cards select on click and via keyboard (arrows, space).
- [ ] Tags input: "+" opens the field focused; typing "Bit Coin,X" becomes "bitcoinx"; Enter adds a chip in the label's colour; suggestions from known tags, arrows + Enter pick one; Backspace on empty removes the last chip; Escape clears then folds; blur on an empty field folds; the fixed `room` chip has no x and typing `room` adds nothing; the fifth tag turns the field read-only with a red "limit reached" that stays until you leave; remove one and the field is live again.
- [ ] Two tags entered quickly (Enter, Enter within ~150 ms) with `enableLatencySim(400)`: both chips stay, none turn into an empty gap. (LiveView lock race, hooks are unit-tested but this needs the real client.)
- [ ] Switch to Unlisted: the tags block disappears and the chips are dropped; back to Listed starts empty; an unlisted room gets no tag files and no "unlisted" tag in the directory, only the badge.
- [ ] Cancel, Escape and clicking outside close the dialog and patch back to `/`; reopening starts clean.
- [ ] Sixth room within an hour → "Slow down" on submit, nothing written.
- [ ] **phone** The dialog is a bottom sheet; cards stack; the tag field fits.

## 6. Room, as creator (A)

- [ ] **smoke** Send: Enter sends, Shift+Enter breaks a line, the row appears pending and flips to the check mark when the SSE event returns; the composer clears and keeps focus; the footer names the storage path.
- [ ] Composer: grows to eight lines then scrolls; 2000-character cap enforced; blank Enter sends nothing; typing shows "… is typing" to B within 2 s and clears 4 s after you stop or on send/blur.
- [ ] Six messages within 5 s → "Slow down — try again in N s" and the sixth is not written.
- [ ] Edit: the composer shows the text with the caret at the end, "editing" state, Escape/Cancel restores, save replaces the row (edited marker), B sees the edit live.
- [ ] Delete: confirm dialog; the row leaves for everyone; the file is gone from the homeserver.
- [ ] Reply: quote block above the composer with a 140-character preview, Cancel clears it, the sent row shows the quote; clicking the quote scrolls to the original and flashes it, also when the original is pages back (it loads until found) or gone ("That message is no longer available.").
- [ ] Reactions: hover/long-press menu offers 👍 ❤️ 😂 👀 🔥 😢; toggling adds/removes your reactor, counts merge across users, B's reactions arrive live; 21 in 10 s → "Slow down".
- [ ] Failed send (stop the homeserver container for a moment): the row shows failed with Retry and Discard; Retry after the homeserver is back confirms; Discard drops it.
- [ ] Header: name, topic, live dot + "N online · M anonymous", copy-link button confirms with a check mark and "Copied" tooltip, settings gear (creator only), tag row with "+" and x on your own tags.
- [ ] Tags from the header: add (chip appears for everyone, file on your homeserver), x removes; a tag another user added has no x for you; an 11th own label or the 21st tag change within an hour → "Slow down".
- [ ] Members: card from `xl`, sheet below (`open_members`/close); creator marked, online dots, B appears when joining and greys out when leaving; hover actions (mute, remove) on desktop, always visible on phone.
- [ ] Remove (ban) B with a reason ≤ 140 chars: "Member removed. Their messages are hidden while the ban is in place."; B's rows leave, their reactions leave every row, B's new messages are ignored, B sees the read-only composer; "Removed by you" list shows B; Restore → "Member restored." and B's history comes back.
- [ ] Mute B (yours only): B's rows and typing vanish in your view only; reload and a second tab of yours agree (persisted marker); Unmute restores. Muting is invisible to B.
- [ ] Settings: rename, topic, Listed → Unlisted (own tags deleted on the homeserver, badge appears, gone from the Directory), Unlisted → Listed (`room` tag written again); "Room updated on your homeserver."; 21 updates in an hour → "Slow down".
- [ ] Close room: confirm → "Room closed. Members' messages stay on their own homeservers."; the page becomes a read-only archive for everyone (B gets "The creator closed this room."), the room moves to the Closed group for members, disappears from the Directory and popular tags, tag files are deleted. Reopening has no UI (a client writing `rooms/<id>` again reopens it; covered by tests).
- [ ] Leave as a plain member still works on an archive (it drops the archive from your lobby).
- [ ] **phone** Room page: header wraps, composer above the tab bar, members sheet slides up, reaction menu reachable by touch.

## 7. Room, as member and viewer (A+B)

- [ ] **smoke** B opens A's link: history in order with names/avatars, Join → "You joined the room.", B appears in members and in A's presence; B sends and A sees it live with the check mark on B's side only.
- [ ] Leave → "You left the room.", B's join marker gone, B can still read (public) but cannot write; Join again works; 21 joins in an hour → "Slow down".
- [ ] Names: a Pubky App profile name wins over a Rooms nickname over the truncated key; changing the nickname on `/me` updates rooms within the profile TTL (or immediately for your own tabs).
- [ ] Pubky App mutes (mainnet only): a user muted in Pubky App is hidden here read-only. Testnet: skip, unit-tested.
- [ ] anon in the same room: counted in "anonymous", never listed, sees everything live.

## 8. History and paging

- [ ] Room with > 100 messages: the newest 100 load; scrolling to the top loads older pages, keeps the reader's place, and keeps paging short pages; the top button appears when a page is empty (a member's homeserver down) and pressing it retries; no request loop in the network tab.
- [ ] "Earlier messages could not be loaded right now." when a member's homeserver is unreachable; Retry history works after it returns.
- [ ] Restart the dev server with the room open: the page reconnects, the room re-bootstraps from the homeservers and shows the same messages (nothing durable lives in the app).

## 9. Degraded states

- [ ] Member with a dead key (post-reboot identity): banner "Live updates from N members are unavailable", member marker, room still readable; an archive whose definition is gone shows as closed.
- [ ] Homeserver down while browsing: bootstrap shows the unavailable state with Retry, no crash, recovers when the container is back.
- [ ] Rate-limited homeserver (`429`): one retry honouring `Retry-After`, then the member is marked unreachable with Retry.
- [ ] Over the live budget (`max_members_subscribed` lowered in config for the test): the notice "over the live-subscription budget" and polled members' messages arriving within a minute.
- [ ] No `NEXUS_URL` (testnet): the Directory still lists rooms this node saw; no errors logged.

## 10. Profile (`/me`)

- [ ] **smoke** Shows the key with a working copy button, the signed-in-with and access-granted facts, the name source, Sign out (secondary, right-aligned; full width on phone).
- [ ] Nickname: save (≤ 32, "Nickname saved to your homeserver."), clear ("Nickname removed."), 11 saves in 10 minutes → "Slow down"; the file lands at `/pub/pubky-rooms/profile.json`.
- [ ] Key that does not resolve (dead PKARR record): the page must not pretend the profile is empty — open item in `findings.md`.

## 11. PWA and offline

- [ ] `/manifest.webmanifest` valid (name, icons incl. maskable, `display: standalone`, `#05050A` colours); install prompt available in Chrome; the installed app opens on the lobby.
- [ ] Service worker: static assets served from cache on reload; HTML is never cached (edit a page, reload, see the change); with the network offline, navigating shows `/offline.html`; the websocket is untouched.
- [ ] iOS: `apple-touch-icon` and theme colour present in `<head>`.

## 12. Operations

- [ ] Logs during the whole pass carry no public keys, IPs or message content at info and above (grep the dev log for a z32 you used).
- [ ] `Subscriptions.info/0` and `/healthz` agree on streams; the capacity warning fires when the pool crosses 80 % (lower `PUBKY_STREAM_POOL_SIZE` to test).
- [ ] `priv/data/directory.dets` survives a restart; rooms, memberships and tags are still listed.

## Runs

| Date | Commit | Who | Scope | Result / findings |
|------|--------|-----|-------|-------------------|
| 2026-09-22 → 09-28 | `6ba3bae`…`8fe25ae` | user + Claude | signed-out screens, signed-in lobby, `/me`, Open-a-room dialog (design first) | see `findings.md` "Design", "Signed-in pass", "Bugs" |

# Status

Maintainers' living handoff. A maintainers' session starts here, then `git log --oneline -20`, then the suites (see `CONTRIBUTING.md`) to confirm the baseline. Keep this file thin: what is deployed, what is next, open questions, reminders, one line per session. How things got here is in `history/` (read-only apart from appending a run row); follow-ups are in `backlog.md` until they are triaged into GitHub issues.

## Deployed
- **Staging**: Fly app `pubky-rooms-staging` (region `fra`, one machine, blue-green), https://pubky-rooms-staging.fly.dev. `deploy.yml` deploys after every green CI run on `main` and ends with the post-deploy smoke (`pubky_rooms/scripts/deploy_smoke.js`). Last code commit deployed: `a098344` (2026-10-01); the docs-only commits since do not start CI. Which commit a node runs is read off `fly releases` against the deploy runs until the "expose the deployed commit" follow-up lands.
- **Production**: none. Deferred (2026-10-01) until the team has tried staging.
- **Staging content**: ten demo rooms opened by the maintainer's staging identity (Introductions, Pubky Rooms feedback, Pubky builders, Design & UX, Show & tell, Homeserver operators, Keys & identity, Bitcoin, Lightning & payments, Off-topic), the unlisted smoke room the deploy workflow writes to, and the 07:54 "Staging smoke" room from 2026-09-30 (220 messages; keep or close, see the questions). Closed test archives stay in their owners' lobbies until closed rooms expire (90 days).
- **CI**: all nine jobs green on `main`; the ninth (`deploy_after_dispatch`) is skipped on push runs by design, which shows as "8/9".

## Next
1. The team tries staging (announcement by the maintainer, 2026-10-01); collect feedback; fix what it turns up, each fix with tests, through the normal push → CI → deploy → smoke path.
2. The maintainer's final look at staging: a room on the phone with the send hint, the archives, the link preview pasted into a chat app, iOS if available.
3. Production decisions (below) → a `production` job in `deploy.yml` with its own token, smoke room and secrets → launch: the repository and the Fly app move to the `pubky` org, `rooms.pubky.app`.
4. Triage `backlog.md` into labelled GitHub issues (labels to add beside the defaults: `pubky-app`, `scale`, `security`, `design`, `ci`, `operations`, `idea`, `upstream`, `qa`).
5. Still to do on the repository: `LICENSE` (maintainer's pick, MIT or Apache-2.0), GitHub topics, private vulnerability reporting switched on in the Security settings.

## Open questions (maintainer's call)
- Production: Fly app name and region (measured next to `homeserver.pubky.app`, the way `fra` was chosen for staging); who controls the `rooms.pubky.app` DNS and whether it is ready for `fly certs add`.
- A mainnet identity in Ring for the production smoke (sign in once, one unlisted room, one stamped message), and which Ring build to use.
- Staging rooms: keep the 07:54 "Staging smoke" room as a demo room or close it; whether the closed test archives should also lose their membership markers so they leave the lobbies before the 90 days.
- Private rooms: all rooms are public in v1; discuss the private homeserver data roadmap with the core team before designing them.
- Room creation limit: five per hour per user stays for now (raising to ten was considered and left).

## Reminders
- The staging smoke cookies (`STAGING_SMOKE_ALICE_COOKIE`, `STAGING_SMOKE_BOB_COOKIE`) expire around **2026-10-30**; refresh recipe in `docs/operations.md`. `FLY_API_TOKEN` expires **2027-09-30**.
- The staging QA harness (two persistent headless Chromium profiles signed in with Ring as `alice` and `bob`, the maintainer's own identity as `owner`, the drive and scenario scripts) lives outside the repository, backed up under the maintainer's `~/.cache/pubky-rooms-qa/`; it holds session cookies and never enters the repository.
- Never raise a live node's log level to debug without setting it back to info. Never stop or restart the local testnet homeserver container (identities and blobs are lost). Rate-limit counters live in node memory, so a redeploy resets them; a rate-limit test on staging locks the identity out for an hour.
- Standing rule for Fly: staging redeploys and machine restarts need no confirmation; every other command that creates or changes something is confirmed first.

## Loose ends
- One intermittent app-suite failure was not captured (backlog, "Operations and CI").
- The 429 on the event-stream connect (backlog, "Upstream and QA").
- The "8/9" CI display and the deployed-commit visibility (backlog, "Operations and CI").

## Sessions (one line each; the narrative is in `history/sessions.md`)
- 2026-09-10/11: M0–M6. The `pubky_ex` library (keys, PKARR, resolver, auth, storage, grant flow, events), the app's vertical slice, membership, presence, profiles, history, edits, replies, reactions, moderation, discovery.
- 2026-09-21: finish phase: tests and CI, polish, telemetry and headers, PWA, README; the QA pause agreed.
- 2026-09-22: the maintainer's run-through as a new visitor (signed-out screens, lobby, `/me`, the Open-a-room dialog); the pubky-app-specs mirror.
- 2026-09-28: room page polish; a tag-input race fixed.
- 2026-09-28/29: two-identity live QA of the room page (send, reply, react, edit, delete, typing, mute, leave, ban).
- 2026-09-29/30: touchbase (the regime, the sequence, review scoping and triage rules); the full checklist on the testnet; fixes.
- 2026-09-30: scoped review 1 with fixes; staging deployed on Fly; the QA harness; §13 on staging overnight.
- 2026-09-30/10-01: automation (testnet CI job, deploy workflow with the post-deploy smoke), the VRT suite, scoped review 2, the full regime on staging (two Escape bugs fixed), the phone-pass fixes, demo prep (the Rooms mark, tooltips, the `room` chip, warning toasts, demo rooms), the avatar sync fix, the team announcement, the repository made public.
- 2026-10-01: docs for contributors (this layout: `docs/maintainers/`, `CONTRIBUTING.md`, the docs index, `CLAUDE.md` as conventions only).

## How a maintainers' session runs
Resume from the prompt "read `docs/maintainers/STATUS.md` and continue" (nothing else points here on purpose, so other people's agents do not pick up our list). Work in small commits with the tests in the same commit; push when a step is verified; every UI change comes with a screenshot. Before ending: update **Deployed**, **Next**, the questions and the session line above; append a run row to `history/checklist-runs.md` when the checklist ran; move anything new that is not being done now into `backlog.md`.

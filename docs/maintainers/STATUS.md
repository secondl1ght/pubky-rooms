# Status

Maintainers' living status: what is deployed, what is next, open questions, reminders. Follow-ups are in `backlog.md` until they are triaged into GitHub issues.

## Deployed
- **Staging**: Fly app `pubky-rooms-staging` (region `fra`, one machine, blue-green), https://pubky-rooms-staging.fly.dev. `deploy.yml` deploys after every green CI run on `main` and ends with the post-deploy smoke (`pubky_rooms/scripts/deploy_smoke.js`). Last code commit deployed: `a098344` (2026-10-01); the docs-only commits since do not start CI. Which commit a node runs is read off `fly releases` against the deploy runs until the "expose the deployed commit" follow-up lands.
- **Production**: none. Deferred (2026-10-01) until the team has tried staging.
- **Staging content**: ten demo rooms (Introductions, Pubky Rooms feedback, Pubky builders, Design & UX, Show & tell, Homeserver operators, Keys & identity, Bitcoin, Lightning & payments, Off-topic), the unlisted smoke room the deploy workflow writes to, and the 07:54 "Staging smoke" room from 2026-09-30 (220 messages; keep or close, see the questions). Closed test archives stay in their owners' lobbies until closed rooms expire (90 days).
- **CI**: all nine jobs green on `main`; the ninth (`deploy_after_dispatch`) is skipped on push runs by design, which shows as "8/9".

## Next
1. Staging is shared for feedback; fixes land with tests through the normal push → CI → deploy → smoke path.
2. A final pass on staging: a room on the phone with the send hint, the archives, the link preview pasted into a chat app, iOS if available.
3. Production decisions (below) → a `production` job in `deploy.yml` with its own token, smoke room and secrets → launch: the repository and the Fly app move to the `pubky` org, `rooms.pubky.app`.
4. Triage `backlog.md` into labelled GitHub issues (labels to add beside the defaults: `pubky-app`, `scale`, `security`, `design`, `ci`, `operations`, `idea`, `upstream`, `qa`).
5. Still to do on the repository: `LICENSE` (MIT or Apache-2.0), GitHub topics, private vulnerability reporting switched on in the Security settings.

## Open questions
- Production: Fly app name and region (measured next to `homeserver.pubky.app`, the way `fra` was chosen for staging); who controls the `rooms.pubky.app` DNS and whether it is ready for `fly certs add`.
- A mainnet identity in Ring for the production smoke (sign in once, one unlisted room, one stamped message), and which Ring build to use.
- Staging rooms: keep the 07:54 "Staging smoke" room as a demo room or close it; whether the closed test archives should also lose their membership markers so they leave the lobbies before the 90 days.
- Private rooms: all rooms are public in v1; the shape they take is a backlog item under "Chat unification".
- Room creation limit: five per hour per user stays for now (raising to ten was considered and left).

- **Chat unification plan** (`BitcoinErrorLog/pubky-chat`, `docs/chat-unification-plan.md`): Rooms' items from it are tracked in `backlog.md` under "Chat unification". The production launch waits for the namespace decision (universal tags under versioned paths).

## Reminders
- The staging smoke cookies (`STAGING_SMOKE_ALICE_COOKIE`, `STAGING_SMOKE_BOB_COOKIE`) expire around **2026-10-30**; refresh recipe in `docs/operations.md`. `FLY_API_TOKEN` expires **2027-09-30**.
- The staging QA harness (persistent headless Chromium profiles signed in with Ring, the drive and scenario scripts) lives outside the repository because it holds session cookies.
- Never raise a live node's log level to debug without setting it back to info. Never stop or restart the local testnet homeserver container (identities and blobs are lost). Rate-limit counters live in node memory, so a redeploy resets them; a rate-limit test on staging locks the identity out for an hour.

## Loose ends
- One intermittent app-suite failure was not captured (backlog, "Operations and CI").
- The 429 on the event-stream connect (backlog, "Upstream and QA").
- The "8/9" CI display and the deployed-commit visibility (backlog, "Operations and CI").

## Keeping this file current
Update **Deployed**, **Next**, the questions and the reminders when they change; anything new that is not being done now goes into `backlog.md`.

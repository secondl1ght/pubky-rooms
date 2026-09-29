# QA

`checklist.md` is the manual pass itself: every flow, the expected result, which items need two identities, and the **smoke** subset to run before each deploy. It replaces ad-hoc regression passes and stands in for the browser end-to-end suite until one exists (post-launch backlog). Record each run in its table.

The finish phase ends with a **QA pause**: the user's first full manual run-through of the app on the testnet, plus Claude's regression pass, before the code-review and security-review skills run on the near-final repository and the first deployment happens.

What to record (decided 2026-09-22, to keep the file useful rather than complete): open or deferred items, decisions with their reason (so they are not re-argued), and bugs whose cause explains a gotcha. Trivial fixed items (a spacing tweak, a reworded hint) are not logged; the commit message is their record.

How to record: one line per finding in `findings.md` under the matching heading (`Bugs`, `Polish`, `Questions`), with the page/flow, what was expected, what happened, and how to reproduce. Claude works the list top-down, marks each row `fixed <commit>`, `deferred → <target>` (with the reason) or `not a bug` (with the explanation), and never deletes a row. Items that turn into design decisions move to the backlog table in `docs/PROGRESS.md`.

Verification rule for fixes: tests and static renders prove markup and CSS; anything that only happens in LiveView's client (JS commands, hooks, click-away, focus, scrolling, dialogs) is verified in the in-app browser as the signed-in identity, at desktop and phone sizes, before it is reported done, and the report says what was checked where. The pane must be visible while probing: in a hidden pane LiveView's class commands wait on an animation frame that never fires (shim `requestAnimationFrame` with `setTimeout` from the JS tool if it cannot be shown).

Two-identity setup for manual testing: the in-app browser (Rooms + Ring Simulator tabs) and the connected Chrome hold separate cookies. Simulator identities vanish when its tab reloads, but Rooms sessions survive in the cookie; a fresh identity is one "Copy link" → Simulator Shortcut mode away.

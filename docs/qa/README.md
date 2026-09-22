# QA

The finish phase ends with a **QA pause**: the user's first full manual run-through of the app on the testnet, plus Claude's regression pass, before the code-review and security-review skills run on the near-final repository and the first deployment happens.

How to record: one line per finding in `findings.md` under the matching heading (`Bugs`, `Polish`, `Questions`), with the page/flow, what was expected, what happened, and how to reproduce. Claude works the list top-down, marks each row `fixed <commit>`, `deferred → <target>` (with the reason) or `not a bug` (with the explanation), and never deletes a row. Items that turn into design decisions move to the backlog table in `docs/PROGRESS.md`.

Two-identity setup for manual testing: the in-app browser (Rooms + Ring Simulator tabs) and the connected Chrome hold separate cookies. Simulator identities vanish when its tab reloads, but Rooms sessions survive in the cookie; a fresh identity is one "Copy link" → Simulator Shortcut mode away.

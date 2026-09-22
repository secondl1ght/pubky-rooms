# QA findings

Seeded on 2026-09-21 from Claude's browser pass over the finish-phase work; the user's manual run-through adds to it.

## Bugs
- (none open)

## Polish
- Flash toasts never auto-dismiss: "Room created on your homeserver", "You joined the room", "The creator closed this room" stay until clicked or navigated away. Pubky App's toasts fade. Decide: auto-hide success/info after ~5 s, keep errors. — open
- A closed room whose members' keys no longer resolve (testnet identities lost their PKARR records) shows "Live updates from N members are unavailable"; correct but the banner competes with the closed notice. Consider hiding live-status banners on archives. — open
- PWA icons are rasterised from `pubky-favicon.svg` by a script (`docs/notes/rooms-app-design.md`, PWA); replace with design-team assets (and a 1024 px iOS icon) before wide release. — open
- `apple-mobile-web-app-capable` is deprecated in favour of `mobile-web-app-capable`; both are set on purpose (older iOS still reads the Apple one). — not a bug
- The mute/remove buttons in the members sheet appear on hover from `sm` up; on a real phone (< `sm`) they are always visible, so touch works. Verify on a device during QA. — open

## Questions
- Member-list discovery without an index (a joiner nobody on this node follows stays unknown until they sign in here) is the documented v1 limitation; revisit with the post-launch spec decision. — tracked in `docs/PROGRESS.md`

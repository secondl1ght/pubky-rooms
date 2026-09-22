# QA findings

Seeded on 2026-09-21 from Claude's browser pass over the finish-phase work; the user's manual run-through adds to it.

## Design (user's run-through, 2026-09-22)
- Header wordmark: "Rooms" not vertically aligned with "Pubky". Cause: the product name was set at 28 px and centred on the 36 px image box, while the SVG letters sit on a baseline 29 px from the top with the x-height of 26 px Inter Tight; "Rooms" rendered larger and ~1 px high. Fix: 26 px, bottom-aligned with a 33 px line-height so both baselines land on 29 px (geometry documented in `UI.Icon.logo/1`); the word gap is 6 px (a word space is 5 px, the SVG "y" runs to the image edge). — fixed
- Header circle buttons (Rooms, New room): hover should match Pubky App. Theirs is the secondary icon button: `bg-white/5` + border inactive, `bg-secondary` active, hover to solid `bg-accent` with the icon colour unchanged, `transition-all`. Ours went to `white/10` and brightened the icon. Tooltips kept. — fixed
- Header buttons: horizontal gap should match Pubky App (`gap-3`, 12 px); ours was 16 px. — fixed
- Header avatar: drop the lime ring on hover (Pubky App's avatar has no hover state). The ring still marks the avatar as the active item on `/me`, like the other buttons' active background. — fixed
- Lobby sidebar: "Your rooms" shown to signed-out visitors, who cannot have rooms. The item links to the lobby itself, so it is now "Lobby" with a door icon (sidebar, header tooltip, mobile tab, page title); the sidebar heading "Rooms" above the links is dropped. "Home" was tried first and discussed; "Lobby" fits the product better. The "Your rooms" section heading over created rooms stays. Test added. — fixed

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

# ADR 0004 — Clean-room UI matching the Pubky App design system

**Status:** accepted (2026-09-10)

**Context.** Pubky Rooms will live at rooms.pubky.app and must feel like Pubky App. The Pubky App codebase (Next.js) has accumulated hacks the user does not want carried over.

**Decision.** Reuse only design data (tokens, type scale, component visual specs) recorded in `docs/notes/pubky-app-design-system.md`, with the Figma as the primary reference for intent. Implement a small, documented component library `PubkyRoomsWeb.UI.*` from scratch (Tailwind v4 CSS-first, Inter Tight, Lucide icons, dark theme only). Never port React code, CSS overrides, or conventions.

**Consequences.** Visual parity is verified by side-by-side screenshots; discrepancies between Figma and production are surfaced to the user rather than silently resolved. The component library can later be extracted for other Pubky Phoenix apps.

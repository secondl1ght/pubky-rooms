# Pubky Rooms design system

Clean-room Phoenix implementation of the Pubky App look (ADR 0004). Everything lives in
`pubky_rooms/assets/css/app.css` (tokens) and `pubky_rooms/lib/pubky_rooms_web/components/ui/*.ex`
(components). The gallery at `/dev/ui` (dev only) renders every component for visual QA against
https://pubky.app. Reference data: `docs/notes/pubky-app-design-system.md`, `docs/notes/figma-reference.md`.

## Tokens (`@theme` in app.css)
- **Colors** (dark only): `background` #05050A, `foreground` white, `card` #1D1D20, `secondary` #303034 /
  `secondary-foreground` #D4D4DB, `muted` / `muted-foreground` #89898F, `accent`, `border`, `input` #525252,
  `ring`, `destructive`, `brand` #C8FF00 (+ `brand-hover`, 10% darker, for solid lime hover), `sidebar-*`,
  `chart-1..6`. Use as Tailwind utilities: `bg-card`, `text-brand`, `border-input`, `bg-brand/16`, …
- **Font**: Inter Tight variable (self-hosted in `priv/static/fonts`, latin + latin-ext), body weight 400.
- **Radii**: `rounded-xs` 4px, `rounded-md` 8px (chips, inputs, post cards), `rounded-xl` 16px (cards, dialogs),
  `rounded-full` (buttons, avatars, nav).
- **Shadows**: `shadow-xs` … `shadow-xl`, tinted rgba(5,5,10).
- **Layout vars**: `--container-max-width` 1200px, `--filter-bar-width` 180px, `--header-offset-main` 144px,
  `--z-sticky-header` 20, `--z-mobile-menu` 30. Z-order: 20 header · 30 mobile header · 40 FAB/tab bar ·
  50 dialogs · 60 toasts.
- **Motion**: `animate-fade-in`, `animate-zoom-in`, `animate-slide-up`, `animate-pulse-soft`; LiveView JS
  transitions in `UI.Transitions` and `UI.Dialog`.
- **Utilities**: `tooltip` (with `data-tip`), `lucide-<name>` icon masks (plugin `assets/vendor/lucide.js`).

## Components (`use PubkyRoomsWeb.UI`)
| Component | Notes |
|---|---|
| `<.icon name="lucide-house" class="size-5" />` | any Lucide icon; color from `currentColor` |
| `<.logo />`, `<.pubky_mark />` | key + "Pubky" wordmark + lime "Rooms" |
| `<.button variant size>` | variants default (lime tint), brand (solid lime), secondary, ghost, outline, destructive, destructive-soft, link, dark, dark-outline; sizes default/sm/lg/icon-sm/icon/icon-lg/tab (48 px pill matching the tab-bar circles); renders `<.link>` with href/navigate/patch |
| `<.fab navigate label />` | 80px translucent circle, lime on hover; in the library for Pubky App parity, not used by any page (the lobby dropped it on 2026-09-22: opening a room is not a frequent action and the header, sidebar and tab bar already offer it) |
| `<.avatar src name pubky size online>` | xs…2xl; generative fallback (signal-color disc + initial), hides broken images; `online` adds the lime presence dot |
| `<.card variant>` + `card_header/title/description/content/footer` | default (`rounded-xl py-6`), post (`rounded-md py-0`), flat |
| `<.badge variant>` | default, secondary, brand, brand-soft, destructive, destructive-soft, outline |
| `<.tag label count selected size static>` | Pubky App tag chip; color from `PubkyRooms.Tags.Color` (exact port of the App's hash); `size="sm"` for cards/headers, `static` renders a span (inside links) |
| `<Linkify.linkify text>` | message text with `http(s)` URLs linked safely (escaped segments, `noopener noreferrer nofollow ugc`, new tab); adds no whitespace |
| `<.input field type label hint>` | text/email/…/textarea (`variant="inline"` for composers)/select/checkbox/hidden; `<.label>`, `<.error>` |
| `<.dialog id show on_cancel>` + `show_dialog/hide_dialog` | centered modal ≥ sm, bottom sheet on mobile; slots title/description/footer |
| `<.live_dot class>` | the "n online" indicator: brand-lime dot with a slow outward ring (`--animate-live-ping`, still under reduced motion); decorative, always next to text |
| `<.flash kind dismiss_after>`, `Layouts.flash_group` | bottom-right toasts (info/success/error); info and success dismiss themselves after 5 s (`AutoDismiss` hook, paused on hover/focus), errors stay |
| `<.spinner>`, `<.skeleton>`, `<.empty_state icon title>` | feedback |
| `<.typography size tag>` | xs/sm/md (500) · lg/xl/2xl (700); `<.section_title>` = 24px light, foreground colour (supporting text under it is muted; pass `text-muted-foreground` to de-emphasise a group) |
| `<.container>`, `<.page>` (slots sidebar/aside), `<.sidebar_item>` | 1200px container; sticky 180px sidebar ≥ lg; aside ≥ xl |
| `Layouts.app current_user active back` | desktop header (logo, icon nav, avatar or sign-in pill), mobile header (back, logo), mobile tab bar (lobby, open a room, avatar or sign-in pill in size `tab`), flash |

## Rules
- Never copy code from `~/CODE/pubky-app`; only the recorded tokens/specs. Verify parity with side-by-side
  screenshots (`/dev/ui` vs pubky.app) and computed styles.
- Prefer components over ad-hoc classes in LiveViews; extend the library when a pattern repeats.
- Every component has `@doc` with an example and declared `attr`/`slot`s.

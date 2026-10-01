# Pubky App design system — reference data (do NOT copy code)

Extracted from the Pubky App repository (`pubky/pubky-app`: Next.js 16, Tailwind v4 CSS-first, shadcn "new-york" atoms, lucide-react, Inter Tight, dark theme only) on 2026-09-10. This file records **tokens and visual specs** so Pubky Rooms looks like the same product. The Phoenix implementation is clean-room (`PubkyRoomsWeb.UI.*`); nothing from the Pubky App codebase is ported as code, CSS hacks, or conventions. The Figma is the primary reference for intent; these production values are the cross-check.

## Tokens (`src/app/globals.css`) — single dark theme on `:root`
```css
--radius: 0.625rem;
--background: oklch(0.118 0.014 284.115);   /* ≈ #05050A */
--foreground: oklch(1 0 0);
--card: oklch(0.232 0.006 285.946);          --card-foreground: oklch(0.951 0.011 286.195);
--popover: oklch(0.118 0.014 284.115);       --popover-foreground: oklch(0.951 0.011 286.195);
--primary: oklch(0.791 0.01 286.174);        --primary-foreground: oklch(0.232 0.006 285.946);
--secondary: #303034;                        --secondary-foreground: #d4d4db;
--muted: oklch(0.311 0.007 285.98);          --muted-foreground: #89898f;
--accent: oklch(0.392 0.007 286.088);        --accent-foreground: oklch(0.951 0.011 286.195);
--destructive: oklch(0.628 0.258 29.234);    --destructive-foreground: oklch(0.971 0.013 17.38);
--border: oklch(0.311 0.007 285.98);         --input: #525252;   --ring: oklch(0.55 0.008 286.145);
--chart-1: oklch(0.517 0.27 263.327); --chart-2: oklch(0.871 0.261 146.685); --chart-3: oklch(0.87 0.148 202.875);
--chart-4: oklch(0.697 0.321 327.72); --chart-5: oklch(0.628 0.258 29.234);  --chart-6: oklch(0.772 0.174 64.552);
--sidebar: oklch(0.232 0.006 285.946); --sidebar-foreground: oklch(0.951 0.011 286.195);
--sidebar-primary: oklch(0.928 0.23 123.978); --sidebar-accent: oklch(0.311 0.007 285.98);
--sidebar-border: oklch(0.311 0.007 285.98); --sidebar-ring: oklch(0.472 0.007 274.863);
--brand: oklch(0.928 0.23 123.978);          /* neon lime ≈ #C8FF00 */
--toast-action-muted: oklch(0.218 0.006 286); --toast-action-muted-hover-border: oklch(0.277 0.006 286);
--scrollbar-size: 10px; --scrollbar-thumb-color: var(--muted-foreground); --scrollbar-track-color: transparent;
```
`@theme`: `--font-sans: Inter Tight, sans-serif`; radii `--radius-xs: 0.25rem; --radius-sm: calc(var(--radius) - 4px); --radius-md: calc(var(--radius) - 2px); --radius-lg: 0.75rem; --radius-xl: 1rem; --radius-2xl: 1.5rem; --radius-3xl: 2rem; --radius-4xl: 3rem`; breakpoint `--breakpoint-xsm: 23.4375rem` (375px); shadows `--shadow-2xs: 0 1px 0 0 rgba(5,5,10,.2); --shadow-xs: 0 1px 2px 0 rgba(5,5,10,.2); --shadow-sm: 0 1px 3px 0 rgba(5,5,10,.25), 0 1px 2px 0 rgba(5,5,10,.25); --shadow-md: 0 4px 6px 0 rgba(5,5,10,.25), 0 2px 4px 0 rgba(5,5,10,.25); --shadow-lg: 0 10px 15px 0 rgba(5,5,10,.25), 0 4px 6px 0 rgba(5,5,10,.25); --shadow-xl: 0 20px 25px 0 rgba(5,5,10,.25), 0 8px 10px 0 rgba(5,5,10,.25)`. Spacing = Tailwind default.
Layout vars: `--container-max-width: 1200px`, `--filter-bar-width: 180px`, `--header-offset-main: 144px`, `--mobile-tab-bar-height: 48px`, `--z-sticky-header: 20`, `--z-mobile-menu: 30`. Base layer: `* { @apply border-border outline-ring/50 }`, `body { @apply bg-background text-foreground }`, `body { font-family: 'Inter Tight'; min-width: 375px; overflow-x: hidden }`. Brand helpers: `.bg-brand .text-brand .border-brand`, `hover:bg-brand/90` = `oklch(from var(--brand) calc(l * 0.9) c h)`.
Z-index convention: `-z-10` background · `z-10` sticky/relative · `z-30` floating · `z-40` FAB/mobile footer/dialog overlay · `z-50` dialogs/sheets/popovers · `z-60` modal controls.

## Typography
Font: **Inter Tight** (Google; production loads via next/font; OG images bundle Regular 400 / Medium 500 / Bold 700). Weights used: 400, 500 (body default), 600 (buttons), 700 (headings, tag labels). Type scale: `xs: text-xs font-medium`, `sm: text-sm font-medium`, `md: text-base font-medium`, `lg: text-2xl font-bold`, `xl: text-4xl font-bold`, `2xl: text-6xl font-bold`; `antialiased`.

## Icons
Lucide (lucide-react). Brand SVGs: `pubky-logo.svg` (109×36), `pubky-favicon.svg`, PubkyIcon, plus social/bitcoin marks. Theme color `#000000`.

## Component specs
- **Button**: base `inline-flex items-center justify-center gap-2 whitespace-nowrap text-sm font-semibold rounded-full border shadow-xs transition-all cursor-pointer disabled:opacity-50 disabled:pointer-events-none focus-visible:ring-[3px] focus-visible:ring-ring/50 focus-visible:border-ring [&_svg]:size-4 [&_svg]:shrink-0`. Variants: `default` `bg-brand/16 text-brand border-brand hover:bg-brand/30`; `brand` `bg-brand text-background border-brand hover:bg-brand/90`; `secondary` `bg-secondary text-secondary-foreground hover:bg-accent`; `ghost` `border-none hover:bg-accent/50 hover:text-accent-foreground`; `outline` `bg-input/30 border-input hover:bg-input/50`; `destructive` `bg-destructive/60 text-destructive-foreground hover:bg-destructive/90`; `destructive-soft` `bg-destructive/16 text-destructive border-destructive hover:bg-destructive/30`; `link` `text-primary underline-offset-4 hover:underline`; `dark` `bg-neutral-900 text-white border-neutral-900 hover:bg-neutral-800`; `dark-outline` `bg-transparent border-neutral-700 hover:bg-neutral-800 hover:text-white`. Sizes: `default h-10 px-4 py-2 gap-1`; `sm h-8 px-3 gap-1.5`; `icon size-9`; `lg h-auto px-8 py-5 text-sm font-bold`.
- **Badge**: `inline-flex items-center justify-center rounded-md border border-transparent px-2 py-0.5 text-xs font-medium gap-1 [&>svg]:size-3`; variants default/secondary/destructive/outline.
- **Avatar**: `relative flex shrink-0 overflow-hidden rounded-full`; sizes `sm h-6 w-6`, `md h-8 w-8`, `default h-10 w-10`, `lg h-12 w-12`, `xl h-16 w-16`. Fallback = generative "facehash" face on one of `#00FF5D #00F0FF #004BFF #FC00FF #FF0000 #FF9900` with the user's initial. Post-header sizes `size-10 | size-12 | size-16`, gaps `gap-3|gap-4|gap-5`, name `text-base leading-5 | text-xl leading-7 | text-2xl leading-8`.
- **Card**: `flex flex-col gap-6 rounded-xl bg-card py-6 text-card-foreground shadow-sm`; header `grid gap-1.5 px-6`; content `px-6`; footer `flex items-center px-6`. Post cards: `rounded-md py-0`, content `gap-4 p-6` (wide layout `p-12`).
- **Dialog/Sheet**: overlay `fixed inset-0 z-50 flex justify-center` (`items-end sm:items-center`); content `max-h-[calc(100dvh-2rem)] gap-6 overflow-y-auto border bg-background p-6 shadow-lg rounded-t-lg border-b-0 sm:max-w-[calc(100vw-2rem)] sm:rounded-xl sm:p-8 sm:border-b`; mobile slides from bottom, desktop fade + zoom-95.
- **Input**: `flex h-9 w-full min-w-0 rounded-md border border-input bg-transparent px-3 py-1 text-base shadow-xs outline-none placeholder:text-input focus-visible:border-ring focus-visible:ring-ring/50 focus-visible:ring-[3px] disabled:opacity-50`.
- **Textarea**: base `flex w-full rounded-md bg-transparent text-base outline-none placeholder:text-muted-foreground`; `default`: `min-h-16 border border-input px-3 py-2 shadow-xs focus-visible:border-ring focus-visible:ring-ring/50`; `inline`: `min-h-6 resize-none border-none p-0 font-medium text-secondary-foreground`.
- **Link**: `cursor-pointer text-brand hover:text-brand/80 transition-colors`; `muted: text-muted-foreground hover:text-brand`; sizes `text-sm | text-lg | text-xl`.
- **Tag chip**: `flex h-8 w-fit max-w-full items-center rounded-md px-3 text-sm font-bold transition-all duration-200`, background `rgba(color, 0.3)`, selected border `1px solid rgba(color, 0.5)` else transparent, hover inset glow `inset 0 0 10px 2px rgba(color, 0.5)`; count `ml-1.5 font-medium text-foreground/50`. Post tag variant adds `backdrop-blur-lg text-white` over a `rgba(5,5,10,.7)` overlay. Max 3 chips inline on posts.
  Deterministic color (port exactly):
  ```
  custom: bitcoin #FF9900, synonym #FF6600, bitkit #FF4400, pubky #C8FF00, blocktank #FFAE00, tether #26A17B
  hash = fold over chars: h = charCode + ((h << 5) - h)   (JS 32-bit int semantics), positive = |h|
  hex2 = (positive & 0xff) as 2-digit hex
  patterns = ["FF00"+hex2, "FF"+hex2+"00", hex2+"FF00", hex2+"00FF", "00"+hex2+"FF", "00FF"+hex2]
  color = "#" + patterns[positive % 6]
  ```
- **Composer**: `rounded-md border border-dashed border-input p-6` (drag state `border-brand`, overlay `bg-brand/10`), textarea placeholder fades on focus.
- **Skeleton/Spinner/Switch/Tooltip/Toast**: standard shadcn new-york looks in the dark palette.

## Shell
- Desktop header: `sticky top-0 z-(--z-sticky-header) w-full bg-linear-to-b from-(--background) from-50% to-transparent sm:py-6`; nav `container max-w-(--container-max-width) mx-auto flex h-24 items-center justify-between gap-4 sm:gap-6 p-6`; nav buttons = `secondary` icon buttons `h-12 w-12 backdrop-blur-md`, inactive `border bg-white/5`, icons `size-6`. Items: Home, Hot, Collections, Settings (+ avatar link). Hidden below `lg`.
- Mobile header: `sticky top-0 z-(--z-mobile-menu) lg:hidden` with logo centered and `size-12` side slots.
- Mobile footer: `fixed bottom-0 z-40 w-full bg-gradient-to-t from-background via-background/95 to-transparent px-3 py-4 lg:hidden`; inner `mx-auto flex max-w-[380px] sm:max-w-[600px] md:max-w-[720px] items-center justify-between`; items `rounded-full p-3`, active `bg-secondary`, inactive `border border-border bg-white/5 backdrop-blur-sm hover:bg-white/10`, icons `h-6 w-6`.
- Page: `container m-auto w-full max-w-(--container-max-width) pb-12`, gutters `px-4 lg:px-6 xl:px-0`, row `flex gap-6`, sticky sidebar `hidden lg:flex flex-col gap-6 w-(--filter-bar-width) sticky` (top 144px), content `min-w-0 flex-1 gap-4`.
- FAB: `fixed right-3 bottom-18 sm:right-10 lg:bottom-6 size-20 rounded-full bg-white/12 backdrop-blur-lg hover:bg-brand text-white shadow-xl z-40`, `Plus` icon `size-10 strokeWidth 0.8`, hover icon black.
- Feed grids: `grid-cols-1 md:grid-cols-2 xl:grid-cols-3`, gaps `gap-3 lg:gap-6`.

## Interop facts learned here
- Pubky App requests capability `/pub/pubky.app/:rw` and identifies to Ring via that path (currently the cookie flow via SDK 0.8; no client id).
- Nexus base URL is runtime-injected (`PUBKY_RUNTIME_NEXUS_URL`, staging `https://nexus.staging.pubky.app`, local `http://localhost:8080`); CDN `{nexus}/static` (`/avatar/<pubky>`, `/files/<pubky>/<id>/<variant>`).
- Nav item lists: `src/components/molecules/Header/Header.tsx` (`NAVIGATION_ITEMS`) and `src/components/molecules/MobileFooter/MobileFooter.tsx` (`authenticatedNavItems`); routes in `src/app/routes.ts`. Nexus client helpers in `src/core/services/nexus/nexus.utils.ts` (`buildNexusUrl`, `queryNexus`).
- Link posts: kind `link`, URL in `content`, `embed` only for reposts. Tags written at `/pub/pubky.app/tags/<id>` with `{uri, label, created_at}`.
- PWA share target `/share` and `web+pubkyring` protocol handler exist; no other cross-app handoff pattern.

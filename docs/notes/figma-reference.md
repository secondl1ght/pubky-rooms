# Figma reference — Pubky SHADCN file

File: https://www.figma.com/design/01ZvjSPZnKTNmaEWz0yJsq/Pubky-SHADCN (file key `01ZvjSPZnKTNmaEWz0yJsq`). Accessible through the user's Figma account via the Figma MCP tools (`get_metadata`, `get_variable_defs`, `get_screenshot`, `get_design_context`). The file is large: never call `get_metadata` on the "Handoff" page without saving to a file; use the node IDs below directly. There are **no Rooms designs**; Rooms is designed by us, consistent with these screens (small variations allowed, must feel the same).

## Verified variables (from `get_variable_defs` on Pubky / Post) — match production CSS
`base/background #05050a`, `base/foreground #ffffff`, `base/card #1d1d20`, `base/muted #303034`, `base/muted-foreground #89898f`, `base/secondary #303034`, `base/secondary-foreground #d4d4db`, `base/accent #454549`, `base/border #303034`, `base/input #525252`, `base/brand #c8ff00`, `pubky colors/alpha/brand-8 #c8ff0014`, `pubky colors/alpha/brand-16 #c8ff0029`, `alpha/30 #05050ab2`, `custom/background dark:input\30 #ffffff0b`, charts `#004bff #00ff5d #00f0ff … #ff0000 #ff9900`.
Type: `font/font-sans Inter Tight`; xs 12/16, sm 14/20, base 16/24, xl 20/28, 2xl 24/32; weights medium 500, bold 700. Radii: xs 4, md 8, full 9999. Spacing: 4/6/8/12/14/16/24/48. Shadows: xs `0 1px 2px rgba(5,5,10,.2)`, sm `0 1px 3px + 0 1px 2px rgba(5,5,10,.25)`.

## Pages
`41492:353039` Pubky - Handoff v26 (all app screens) · `18463:90813` Pubky - Building Blocks (components) · `22:1400` Typography · `34:6` Button · `23:988` Avatar · `23:995` Badge · `46:65` Card · `112:477` Dialog · `112:454` Drawer · `89:189` Dropdown Menu · `65:520` Input · `177:367` Textarea · `216:3314` Sheet · `64:243` Skeleton · `118:2756` Sonner (toasts) · `60:438` Switch · `183:417` Tabs · `193:1388` Popover · `1:433` Icons · `43:396` Assets.

## Key component nodes (Building Blocks)
- Navbar: `19584:5368` Signed in · `18345:201760` Sign In · `19011:15134` Regular · `21423:99720` Profile Desktop · `20617:69117` Profile Mobile · `20139:90257` Bottombar (mobile tab bar) · `31244:187840` Tab.
- Post: `20369:87079` Post (states incl. tags expanded, composer) · `24745:99597` Post / Main · `22623:86952` Post / Visual · `38371:87721` Post / List · `19382:22737` Post / Header · `19386:25150` Post / Content · `20341:33119` Content / Text · `21510:114724` Content / Link · `19468:19592` Actions · `19382:22730` Post / Time · `19398:26406` Post / Tag · `19420:44389` Post / Tags · `20695:148056` TagsExpanded · `19402:44195` NewTagHorizontal · `29817:116733` Tag Suggestions · `19544:16148` ThreadConnector.
- Dialogs: `21066:103231` Dialog / Post (composer) · `20869:119880` Dialog / Reply · `43396:138005` Dialog / Signin · `31457:610726` Dialog / JoinPubky · `42267:251841` Dialog / CreateCustomFeed · `34440:151334` Dialog / NewCollection.
- Layout: `19578:18148` Sidebar (right) · `19902:16539` Sidebar / Sections · `19323:20748` Filterbar (left) · `19323:14810` Filterbar / Items · `20139:105690` Menu Slide (mobile drawer) · `19729:9886` Search.
- Profile/users: `20616:40807` Profile / Header · `20616:41624` Profile / Avatar · `20341:33137` User · `19432:22073` User / Suggestion · `20698:226446` Profile / Tags · `25999:190047` UserHover.
- Feed: `20532:37956` Feed / Posts · `20412:39448` Feed / Title · `25524:182904` NewPosts pill · `21143:102761` Feed / Preview.
- Misc: `45995:231734` Badge · `19487:35552` Link · `24722:124974` Spinner · `23788:107928` Animation / Check · `20300:87554` Dropdown · `35145:317982` Ring / Dynamic QR (QR with Pubky logo centered) · `20940:98732` Backgrounds · `19647:13882` BrandGraphic · `23263:120285` Divider.

## Key screens (Handoff v26)
Desktop 1280: `41492:353357` Feed - Column · `41492:353932` Feed - Wide · `41492:353952` Feed - Visual · `41492:354058` Post - Column · `41492:354100` Reply · `41492:354126` Hot · `41492:354140` Profile · `41492:354214` Settings Account · `41492:353324` Sign in · `41492:353111` Create account - QR · `41492:354038` Search.
Mobile 375: `41492:354731` Feed · `41492:354691` Sign in · `41492:354989` Post by John · `41492:355028` Reply · `41492:355084` Profile John · `41492:355154` Settings Account · `41492:354827` Explore.

## Visual observations (for Rooms design decisions)
- Near-black page (`#05050A`), cards `#1D1D20` with `rounded-md`/`rounded-xl`, no visible borders on cards; separation by tone, not lines.
- Header: logo (lime key icon + "Pubky" wordmark), full-width pill search (`rounded-full`, dark), circular icon nav buttons with subtle borders and backdrop blur, avatar with a lime notification count badge. Mobile: centered logo, filter icon left, lightbulb right; bottom tab bar of circular icon buttons plus a large circular "+" FAB above it.
- Three-column desktop: left filter bar (Reach / Sort / Layout / Content sections, plain lists with icons, active item highlighted), center column ~600px of stacked cards, right sidebar (Who to follow, Active users, Hot tags, Experimental, Feedback) with `Typography / H3`-style grey section titles.
- Post card: avatar 40px, bold name, muted key/time, body text, tag chips row (colored chips: label bold + count muted), action pills right-aligned (tag count, replies, reposts, bookmark, more) as small `rounded-full` outline buttons.
- Composer: dashed-border card ("What's on your mind?"), when active shows avatar + name + counter `21/2000`, tag input, action icons (emoji, image, file, Drafts pill), lock toggle, and a lime `Post` pill button (`bg-brand/16 text-brand border-brand`, filled lime when ready).
- Tags: `rounded-md` chips, ~32px tall, bold label, background = tag color at 30% with count in dimmer text; selected = subtle border; "add tag" is a dashed/outlined input chip with a search icon.
- Sign in screen: big headline "Sign in to **Pubky.**" (accent word in lime), grey subtitle, two large `#1D1D20` cards; the sovereign card shows a key illustration and a white QR with the Pubky logo centered. Reuse this pattern for "Sign in to Pubky **Rooms**." with the Ring QR.
- Toasts (Sonner) bottom-right dark cards; dialogs are dark cards with `rounded-xl`, mobile sheets slide from bottom.
- Buttons are pills (`rounded-full`); primary = lime tint with lime text, strong CTA = solid lime with black text; secondary = `#303034`; icon buttons are circles.

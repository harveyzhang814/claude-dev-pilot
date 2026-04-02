# Design System — Agent Dev Pilot

## Product Context
- **What this is:** A macOS menubar app that monitors Claude Code AI sessions and surfaces events as native notifications and a popover UI
- **Who it's for:** Developers running Claude Code daily — solo builders who want ambient awareness of their AI agents without context-switching
- **Space/industry:** Developer tools, AI coding assistants, macOS utilities (peers: Raycast, Linear, Warp)
- **Project type:** Native macOS app with SwiftUI popover + menubar icon

## Aesthetic Direction
- **Direction:** Industrial / Precision Instrument
- **Decoration level:** Minimal — typography and color do all the work
- **Mood:** Like Instruments.app crossed with a cockpit. Near-invisible chrome. The UI disappears so the signal stands out. Nothing is decorative — every element is load-bearing.
- **Reference sites:** raycast.com, linear.app, warp.dev (studied 2026-04-01)

## Typography
- **Session IDs / Event data:** JetBrains Mono — monospace signals "this is technical output, not UI copy". Immediately communicates developer-native.
- **UI labels / Descriptions:** Geist Sans — tight, neutral, developer-native. Avoids the over-used Inter.
- **Timestamps / Counts:** Geist with `font-variant-numeric: tabular-nums` — columns stay aligned as numbers update.
- **Code:** JetBrains Mono (already primary for data)
- **Loading:** Google Fonts CDN — `https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Geist:wght@300;400;500;600&display=swap`
- **Scale:**
  - xs: 10px — timestamps, secondary metadata
  - sm: 11px — badges, labels, footer stats
  - base: 12px — session event descriptions, session list rows
  - md: 13px — body text, notification descriptions
  - lg: 15px — session IDs (mono)
  - xl: 22px — section headings
  - 2xl: 28px — empty state icon / hero

## Color
- **Approach:** Semantic-only. Color is never decorative. Color = status. If something is amber, it's running. If it's red, it needs you.

| Token         | Hex       | Usage                                      |
|---------------|-----------|--------------------------------------------|
| Background    | `#1C1C1E` | App/popover background — macOS system dark |
| Surface       | `#2C2C2E` | Elevated panels, cards                     |
| Surface 2     | `#3A3A3C` | Hover states, inset backgrounds            |
| Surface 3     | `#48484A` | Borders, deep insets                       |
| Text          | `#FFFFFF` | Primary text                               |
| Text Muted    | `#8E8E93` | Descriptions, secondary labels             |
| Text Faint    | `#636366` | Timestamps, footer stats, empty states     |
| Separator     | `rgba(255,255,255,0.08)` | Dividers, borders          |
| Action        | `#FF453A` | `permissionNeeded` — unmissable red. Needs you now. |
| Running       | `#FF9F0A` | `taskStarted` — warm amber. Alive, not alarming. Deliberately NOT system blue. |
| Completed     | `#32D74B` | `taskCompleted` — macOS system green       |
| Error         | `#FF6961` | `taskError` — softer red, distinct from Action |

- **Dark mode:** This is a dark-only app. No light mode. Native macOS dark system colors.
- **No branding accent color.** The running amber `#FF9F0A` is the closest thing to an accent — it's earned by being the "alive" state, not chosen for brand reasons.

## Spacing
- **Base unit:** 4px
- **Density:** Compact — developers hate wasted space. The popover is 280–320px wide and every row earns its height.
- **Scale:**
  | Token | Value | Use |
  |-------|-------|-----|
  | 2xs   | 2px   | Icon padding, dot margins |
  | xs    | 4px   | Inline gaps |
  | sm    | 8px   | Internal padding tight |
  | md    | 12px  | Row padding vertical |
  | lg    | 14–16px | Panel padding horizontal |
  | xl    | 24px  | Section gaps |
  | 2xl   | 32px  | Major section spacing |
  | 3xl   | 48px  | Page/empty state padding |

## Layout
- **Approach:** Data-first, grid-disciplined
- **Popover:** Fixed 280–300px wide. Tall enough for content (no fixed height). Arrow pointing to menubar icon.
- **Structure:** Header (title + count) → attention banner if needed → session list → footer (stats + prefs link)
- **Attention items float to top** — the most urgent signal is always first in the list
- **Max content width:** 300px (popover is the entire UI)
- **Border radius:** sm: 4px (buttons), md: 8px (cards, banners), lg: 12px (popover window)

## Motion
- **Approach:** Minimal-functional. Motion aids comprehension only.
- **Easing:** enter: ease-out / exit: ease-in / move: ease-in-out
- **Duration:**
  - micro: 50–100ms — dot state changes
  - short: 150ms — new event fade-in
  - medium: 200–250ms — popover open/close
  - long: never — nothing bouncy, nothing choreographed
- **New events:** fade in with `opacity 0→1` over 150ms ease-out
- **Status dot:** instant color change (no transition) — signal clarity over smoothness
- **No spring animations. No scale bounces.**

## Float Window

A persistent desktop status indicator based on the **minimal attention principle** — three states of increasing information density.

### Color tokens (extends base system)

| State | Dot color | Background tint |
|-------|-----------|-----------------|
| `waiting` | `#FF453A` (action) — pulsing | `rgba(255,69,58,0.09)` |
| `idle` | `#FF9F0A` (amber) — static | `rgba(255,159,10,0.07)` |
| `running` | `#30D158` (green) — static | none |
| `stale` | `#636366` (faint) — static | none |

### State 1 — Compact

- Shape: capsule pill, `.regularMaterial` background (frosted glass)
- One 8pt dot per session, `gap: 5pt`, `padding: 10pt` horizontal + vertical
- Max 5 dots shown
- `waiting` dot: slow opacity pulse `1.0 → 0.2`, 1.5s ease-in-out infinite
- Pill size never changes regardless of state

### State 2 — Hover

- Width: `280pt`, corner radius: `12pt`
- Single-line rows: `[dot] [name] [status text] [time]`
  - Dot: 8pt, color = session state
  - Name: 12px/500, `flex:1`, truncated
  - Status text: 11px, same color as dot, right-aligned
  - Time: 10px, `text-faint`, `tabular-nums`, rightmost
- Row height: `~36pt` (10pt vertical padding)
- `waiting` row: `rgba(255,69,58,0.09)` background
- `idle` row: `rgba(255,159,10,0.07)` background
- `running`/`stale` rows: no background
- Row hover: `surface2 (#3A3A3C)` background
- Click row: focus corresponding terminal window
- **Sort**: original session order preserved; `stale` sessions sink to bottom
- Toolbar (compact, `~28pt` tall): Settings icon · Dismiss spacer · Expand icon
  - No Dismiss All — state is hook-driven, not manually managed
- Collapse: 1s delay after mouse exit, then 300ms ease-in-out → compact

### State 3 — Expanded

- Width: `360pt`, max height `480pt` (scrollable)
- Session label (lightweight, matches hover row): `[dot] [name] [status text]`
  - Label font: 11px/500, `text-muted`
  - Status font: 10px, dot color
  - Padding: `12pt` top, `6pt` bottom
- Notification cards are the primary content (not session rows)
  - `action` tier: `rgba(255,69,58,0.12)` background + `rgba(255,69,58,0.2)` border, title in `#FF453A`
  - `review` tier: `surface (#2C2C2E)` background + separator border, title in `#FFFFFF`
  - Card padding: `9pt` vertical, `11pt` horizontal, `8pt` corner radius
  - Body text: 11px, `text-muted`
  - Time: 10px, `text-faint`, `tabular-nums`
  - No swipe-to-dismiss — state driven by hooks only
- Running session with no events: `"Working..."` italic placeholder, `text-faint`
- Footer: Session Panel (accent blue) · Quit

### Transitions

| Transition | Delay | Duration | Easing |
|-----------|-------|----------|--------|
| Hidden → Compact | 0ms | 150ms | opacity fade |
| Compact → Hover | 0ms | 200ms | ease-out |
| Hover → Compact | 1000ms | 300ms | ease-in-out |
| Any → Expanded | 0ms | 200ms | ease-out |
| Waiting pulse | — | 1500ms | ease-in-out ∞ |

**Position anchor**: top-Y pinned across all transitions; width expands symmetrically from center-X. Default position: top-center below menubar. Persists across drags via `UserDefaults`.

## Decisions Log

| Date       | Decision | Rationale |
|------------|----------|-----------|
| 2026-04-01 | Amber (#FF9F0A) for running state instead of system blue | Every other dev tool uses blue. Amber is alive and urgent-but-not-alarming. Avoids generic feel. |
| 2026-04-01 | JetBrains Mono for session IDs and data | Signals "this is terminal output," reinforces the tool's identity as a developer companion. Risk accepted: might feel dev-bro, but that's the right audience. |
| 2026-04-01 | Near-zero branding chrome | No logo in popover, no accent window frame. Maximum cognitive space for the signal. Requires precise execution to not feel unfinished. |
| 2026-04-01 | Semantic-only color system | Color = status, not decoration. Users never have to guess what a color means. |
| 2026-04-01 | Initial design system created | Created by /design-consultation. Researched Raycast, Linear, Warp. |
| 2026-04-03 | Float Window design approved | Three-state system (compact/hover/expanded). Running=green, waiting=red pulse, idle=amber, stale=gray+disabled. No manual dismiss — state driven by hooks. Session order preserved, stale sinks to bottom. |

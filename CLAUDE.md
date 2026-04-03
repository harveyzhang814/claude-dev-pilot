# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git workflow

Before starting any new feature or bug fix, always create a new branch from `staging`:

```bash
git fetch origin
git checkout staging
git pull origin staging
git checkout -b feat/short-description   # or fix/short-description
```

- Features → `feat/<short-description>`
- Bug fixes → `fix/<short-description>`
- Never commit directly to `staging` or `main`
- Each independent piece of work gets its own branch

## Commands

```bash
# Build
swift build -c debug

# Run tests (all)
swift test

# Run a single test target
swift test --filter AgentDevPilotTests
swift test --filter ServerTests

# Run a single test class or method
swift test --filter SessionLifecycleTests
swift test --filter SessionLifecycleTests/testProcessEvent

# Build and launch the app as a proper .app bundle (required for notifications)
make run

# Build bundle without launching
make bundle

# Clean
make clean
```

**Important:** `swift run` is not sufficient for development — the app requires a proper `.app` bundle with `CFBundleIdentifier` to register with `UNUserNotificationCenter`. Always use `make run` to launch.

## Architecture

Agent Dev Pilot is a macOS menubar app that receives Claude Code and Cursor IDE hook events via HTTP and surfaces them as native notifications and a popover UI.

### Event flow

```
Claude Code hook → notify.sh → POST /event (port 9876) → EventHandler
  → SessionLifecycleService.handleSessionLifecycle() for SessionStart/SessionEnd
  → EventMapper (HookPayload → DevEvent) for Notification/UserPromptSubmit hooks
  → SessionLifecycleService.processEvent() (persist event, update session state)
  → StopWindowService (coalesces Stop + Notification within 2s to resolve idle/waiting)
  → NotificationBatcher (debounce/throttle)
  → NotificationService (UNUserNotificationCenter)
  → AppState publishes to SwiftUI via GRDB ValueObservation

Cursor hook → cursor-notify.sh → POST /cursor-event (port 9876) → EventHandler.postCursorEvent
  → CursorNormalizer.normalize() (CursorHookPayload → HookPayload, injects tool="cursor")
  → same pipeline as above (SessionStart/SessionEnd → lifecycle; Stop → StopWindowService)
  → unknown hook events silently dropped (200 OK, no DevEvent created)
```

### SPM targets

- **Core** (`Sources/Core/`) — models, stores, services. No UI, no server dependencies. Used by both the app and test targets.
- **Server** (`Sources/Server/`) — Hummingbird HTTP server. Depends on Core.
- **AgentDevPilot** (`Sources/App/`) — SwiftUI executable. Depends on Core + Server.
- **AgentDevPilotTests** (`Tests/`) — unit tests for Core (excludes `Tests/ServerTests/`).
- **ServerTests** (`Tests/ServerTests/`) — integration tests for the HTTP layer using `HummingbirdTesting`.

### Key types

| Type | Location | Role |
|------|----------|------|
| `HookPayload` | Core/Models | Raw JSON from Claude Code hooks. Optional `tool` field (nil = "claude-code") |
| `CursorHookPayload` | Core/Models | Raw JSON from Cursor hooks (snake_case CodingKeys, `workspace_roots` defaults to `[]`) |
| `CursorNormalizer` | Core/Models | Converts `CursorHookPayload` → `HookPayload`: maps `workspace_roots[0]`→`cwd`, PascalCase event names, injects `tool="cursor"` |
| `DevEvent` | Core/Models | Persisted event (GRDB `FetchableRecord`/`PersistableRecord`) |
| `DevSession` | Core/Models | Session grouping events by `session_id`. `tool` field: "claude-code" or "cursor" |
| `EventMapper` | Core/Models | Maps `HookPayload` → `DevEvent`, infers `EventType` and `AttentionTier` |
| `DatabaseManager` | Core/Store | Opens GRDB `DatabasePool`, runs migrations |
| `EventStore` / `SessionStore` | Core/Store | CRUD + pruning. `EventStore.fetchGroupedBySession(sessionIds:limit:in:)` fetches ≤5 undismissed non-background events per session. Always use typed GRDB queries, never raw SQL for updates |
| `HookLog` / `HookLogStore` | Core/Models + Core/Store | Debug audit log: one row per incoming HTTP request, inserted before any business logic. Fields: `hookEventName`, `sessionId`, `notificationType`, `rawPayload` (true raw JSON), `receivedAt`. Parse failures stored with `hookEventName = "PARSE_ERROR"`. Pruned by same `retentionDays` as events |
| `SessionLifecycleService` | Core/Services | Handles `SessionStart`/`SessionEnd` hook lifecycle and `processEvent()` for event-driven state transitions |
| `StopWindowService` | Core/Services | Actor that coalesces Stop + Notification hooks within a 2s window; resolves session to `.idle` (agentStopped event written) or `.waiting` |
| `NotificationBatcher` | Core/Services | Per-session batching (>3 events/2s) + global throttle (5/10s) |
| `AuthTokenService` | Core/Services | Generates and persists a 32-byte hex token at `~/.agent-dev-pilot/token` (0600) |
| `HookInstaller` | Core/Services | Embeds `notify.sh` and `cursor-notify.sh` scripts; writes to `~/.agent-dev-pilot/hooks/`. `claudeCodePrompt()` and `cursorAgentPrompt()` generate hook registration prompts |
| `EventServer` | Server | Hummingbird app builder. `buildApp()` for tests, `start()` for production. `configureRoutes` registers `/event` and `/cursor-event` |
| `AuthMiddleware` | Server | Bearer token validation. `/health` bypasses auth |
| `AppState` | App | `@Observable` root object. Owns DB, server task, batcher, stale timer |
| `PopoverViewModel` | App/ViewModels | Single atomic `ValueObservation` populates `activeSessions: [DevSession]` (idle+busy+waiting, startedAt desc) and `eventsBySession: [String: [DevEvent]]` together. Also keeps `activeSessionCount`/`sessionStartTimes` for backward compat |
| `SessionPanelViewModel` | App/ViewModels | Separate `ValueObservation` for the session panel, splits all sessions into `activeSessions`, `completedSessions`, `staleSessions` |
| `FloatWindowController` | App/FloatWindow | Owns the floating `NSPanel`; drives `hidden/compact/hover/expanded` state machine. Reacts to `PopoverViewModel` changes and mouse tracking |
| `TerminalFocusService` | App/Services | Routes focus requests to `GhosttyFocuser` or `TerminalAppFocuser` based on `session.terminalApp` |
| `SessionGroupView` | App/Views | Renders one session group: header row (status dot + project name + capsule tag + optional tool badge) + `EventCardView` list or "Working..." placeholder. `sessionStatusTag`/`sessionStatusColor`/`sessionToolBadge` are internal free functions (not private, accessible via `@testable`) |
| `MenubarPopover` | App/Views | Session-grouped popover: `ForEach(activeSessions)` → `SessionGroupView` with dividers; empty state shows `terminal` SF symbol |

### AttentionTier

| Tier | EventType | UI behavior |
|------|-----------|-------------|
| `.action` | `permissionNeeded` | Red bar in popover, native notification |
| `.review` | `agentStopped` (idle-ready) | Green "ready" card in popover |
| `.background` | `promptSubmitted`, `authSuccess` | Session panel only; excluded from popover |

### Database

- SQLite via GRDB, WAL mode, stored at `~/Library/Application Support/AgentDevPilot/db.sqlite`
- Migrations: `v1_initial` → `v2_dismissed` → `v3_session_cwd` → `v4_session_terminal` (`tty`/`terminal_app`) → `v5_session_status` (renames `running`→`idle`, `error`→`completed`) → `v6_event_types` (renames `taskStarted`→`promptSubmitted`, `taskCompleted/taskError`→`agentStopped`) → `v7_session_custom_name` → `v8_hook_logs` (creates `hook_logs` debug table)
- Tests use in-memory DB via `DatabaseManager.openInMemoryDatabase()`
- `ValueObservation` closures must always read every table they need to track — an early-return guard that skips a table read will cause that table to be unregistered from the observation

### Auth

Token at `~/.agent-dev-pilot/token` (0600 permissions). `notify.sh` reads this token and sends it as `Authorization: Bearer <token>`. The same token is loaded by `AppState.start()` via `AuthTokenService.ensureToken()`.

### Session state machine

States: `idle` (active, no task) | `busy` (executing) | `waiting` (needs user input) | `completed` (SessionEnd received) | `stale` (inactive 30 min)

State transitions in `SessionLifecycleService`:
- `SessionStart` hook → create session as `.idle`; if completed/stale, reopen to `.idle`
- `SessionEnd` hook → `.completed` (stamps `ended_at`)
- `promptSubmitted` / `authSuccess` event → `.busy`; all prior events for session auto-dismissed
- `permissionNeeded` event → `.waiting`
- `agentStopped` event → no direct transition; `StopWindowService` resolves after 2s window: Stop-only → `.idle`, Stop+Notification → `.waiting`
- Any event on a completed/stale session → reopen to `.idle`
- 60s timer in `AppState` → `.stale` for sessions with no activity for 30 minutes

### Stale session and pruning

- Stale detection: 60-second timer in `AppState`, marks sessions with no activity for 30 minutes as `.stale`
- Pruning: lazy, once per day, configurable retention via `UserDefaults` key `retentionDays` (default 30)

### UserDefaults keys

| Key | Default | Purpose |
|-----|---------|---------|
| `serverPort` | 9876 | HTTP server port |
| `retentionDays` | 30 | Event pruning age |
| `soundEnabled` | true | Notification sound |
| `onboardingCompleted` | false | Onboarding gate |
| `floatWindowX` | — | Saved X origin for float window (persisted across launches) |
| `floatWindowTopY` | — | Saved top edge Y for float window (persisted across launches) |

### notify.sh

Script content is embedded in `HookInstaller.scriptContent` (the canonical source of truth — not in `Resources/`). `HookInstaller.installScript()` writes it to `~/.agent-dev-pilot/hooks/notify.sh` (0755), skipping the write if content is unchanged. Fire-and-forget — uses `&` so it never blocks Claude Code. Enforces 64KB payload limit via `head -c 65536`. If the app is not running, events are silently dropped.

Claude Code hooks registered: `Notification`, `SessionStart`, `SessionEnd`. The `UserPromptSubmit` hook is also handled. Use `HookInstaller.claudeCodePrompt()` to generate the settings.json merge prompt.

### cursor-notify.sh

Script content is embedded in `HookInstaller.cursorScriptContent`. `HookInstaller.installCursorScript()` writes it to `~/.agent-dev-pilot/hooks/cursor-notify.sh` (0755). Posts to `/cursor-event` endpoint. Respects `$AGENT_DEV_PILOT_PORT` env var (defaults to 9876). Fire-and-forget — never blocks Cursor.

Cursor hooks registered: `sessionStart`, `sessionEnd`, `stop`. Use `HookInstaller.cursorAgentPrompt()` to generate a prompt the user pastes into Cursor Agent, which merges hooks into `~/.cursor/hooks.json`.

### Float window

`FloatWindowController` owns a borderless, always-floating `NSPanel` with its own state machine:
- `hidden` → `compact` (auto, when active sessions + events appear)
- `compact` → `hover` (on mouse enter; shows session rows + toolbar)
- `hover` / `expanded` → `compact` (on mouse exit after 1s delay)
- `compact` / `hover` → `expanded` (on click/tap or notification card tap)
- `expanded` → `compact` / `hidden` (on toggle or mouse exit)

The panel renders `FloatWindowCompactView` (compact), `FloatWindowHoverView` (hover), or `MenubarPopover` (expanded). `TrackingView` wraps the content for mouse enter/exit events. Position is persisted via `floatWindowX`/`floatWindowTopY` UserDefaults; the top edge is pinned across height changes (only height changes on expand/collapse).

## Testing patterns

- All store/service tests use `DatabaseManager.openInMemoryDatabase()` — never a file-based DB
- Server tests use `HummingbirdTesting` with `buildApp()` (not `start()`, which binds to a port)
- `SessionLifecycleService` and `NotificationBatcher` are the highest-risk components for concurrency bugs; test edge cases (rapid events, state reopening)

---

# gstack

Use the `/browse` skill from gstack for all web browsing. Never use `mcp__claude-in-chrome__*` tools directly.

Available gstack skills:
- `/office-hours` - Office hours / Q&A session
- `/plan-ceo-review` - CEO review of a plan
- `/plan-eng-review` - Engineering review of a plan
- `/plan-design-review` - Design review of a plan
- `/design-consultation` - Design consultation
- `/design-shotgun` - Rapid design generation
- `/design-html` - HTML design generation
- `/review` - Code review
- `/ship` - Ship / deploy workflow
- `/land-and-deploy` - Land and deploy
- `/canary` - Canary deployment
- `/benchmark` - Benchmarking
- `/browse` - Web browsing (use this for ALL web browsing)
- `/connect-chrome` - Connect to Chrome browser
- `/qa` - QA testing
- `/qa-only` - QA only (no fixes)
- `/design-review` - Design review
- `/setup-browser-cookies` - Setup browser cookies
- `/setup-deploy` - Setup deployment
- `/retro` - Retrospective
- `/investigate` - Investigation / research
- `/document-release` - Document a release
- `/codex` - Codex agent
- `/cso` - CSO review
- `/autoplan` - Automatic planning
- `/careful` - Careful mode
- `/freeze` - Freeze changes
- `/guard` - Guard / protect
- `/unfreeze` - Unfreeze changes
- `/gstack-upgrade` - Upgrade gstack
- `/learn` - Learning / documentation

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review

## Design System
Always read DESIGN.md before making any visual or UI decisions.
All font choices, colors, spacing, and aesthetic direction are defined there.
Do not deviate without explicit user approval.
In QA mode, flag any code that doesn't match DESIGN.md.

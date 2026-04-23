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
swift test --filter AgentPilotTests
swift test --filter ServerTests

# Run a single test class or method
swift test --filter SessionStateReducerTests
swift test --filter HookStreamCoordinatorTests/testStopWindowResolvesToIdle

# Build and launch the app as a proper .app bundle (required for notifications)
make run

# Build bundle without launching
make bundle

# Clean
make clean
```

**Important:** `swift run` is not sufficient for development — the app requires a proper `.app` bundle with `CFBundleIdentifier` to register with `UNUserNotificationCenter`. Always use `make run` to launch.

**Important:** When the app is launched via `make run`, `print()` and swift-log output go to macOS unified logging — not the terminal. Use the debug capture scripts to tap them:

```bash
# Debug logging
bash harness/debug/start-log-capture.sh   # start capture → tmp/logs/app.log
bash harness/debug/verify-logs.sh         # verify all sources OK
bash harness/debug/run-tests.sh           # run tests, output → tmp/logs/test.log
tail -f tmp/logs/app.log                  # live app log
```

See `harness/debug/README.md` for query patterns and full reference.

## Architecture

Agent Pilot is a macOS menubar app that receives Claude Code and Cursor IDE hook events via HTTP and surfaces them as native notifications and a popover UI.

### Event flow

Two parallel event sources feed the same coordinator pipeline:

```
[Path 1 — HTTP hooks]
Claude Code hook → notify.sh → POST /event (port 9876) → EventHandler
  → HookLog INSERT (raw audit, per request)
  → HookEventClassifier.classify(payload) → HookEvent (typed enum)
  → HookStreamCoordinator.process(payload)
      → SessionStateReducer.reduce(state, event) → (nextState, [Action])
      → execute(actions):
            upsertSession / updateSessionStatus  → GRDB writes
            insertDevEvent                       → GRDB writes
            dismissPriorEvents                   → GRDB writes
            startStopWindow / cancelStopWindow   → internal Task management
  → onEvent callback → NotificationBatcher (debounce/throttle)
  → NotificationService (UNUserNotificationCenter)
  → AppState publishes to SwiftUI via GRDB ValueObservation

Cursor hook → cursor-notify.sh → POST /cursor-event (port 9876) → EventHandler.postCursorEvent
  → CursorNormalizer.normalize() (CursorHookPayload → HookPayload, injects tool="cursor")
  → same pipeline as above
  → unknown hook events silently dropped (200 OK, no DevEvent created)

[Path 2 — SessionFileWatcher (fallback / redundancy)]
DispatchSourceTimer (3s) → SessionFileWatcher.poll()
  → scanActiveFiles(~/.claude/projects/, mtime < 30min, skip subagents/)
  → readNewLines(jsonl, offset) → JournalEventNormalizer.normalize(entry)
      "user" (string content)   → UserPromptSubmit
      "assistant" (AskUserQuestion tool_use) → Notification/permission_prompt
      "system" (stop_hook_summary) → Stop
      "progress" (legacy ≤v2.1.81) → SessionStart / Stop / UserPromptSubmit
  → HookLog INSERT (eventSource = "file_watcher")
  → HookStreamCoordinator.process(payload)  [same pipeline as Path 1]
```

Path 2 is enabled by default (`fileWatcherEnabled` UserDefaults key, default `true`). It catches activity when HTTP hooks are unavailable (app restart mid-session, hook registration failure). Only JSONL entries that map to meaningful state-machine events are forwarded; all others return nil and are dropped.

### SPM targets

- **Core** (`Sources/Core/`) — models, stores, services. No UI, no server dependencies. Used by both the app and test targets.
- **Server** (`Sources/Server/`) — Hummingbird HTTP server. Depends on Core.
- **AgentPilot** (`Sources/App/`) — SwiftUI executable. Depends on Core + Server.
- **AgentPilotTests** (`Tests/`) — unit tests for Core (excludes `Tests/ServerTests/`).
- **ServerTests** (`Tests/ServerTests/`) — integration tests for the HTTP layer using `HummingbirdTesting`.

### Key types

| Type | Location | Role |
|------|----------|------|
| `HookPayload` | Core/Models | Raw JSON from Claude Code hooks. Optional `tool` field (nil = "claude-code") |
| `CursorHookPayload` | Core/Models | Raw JSON from Cursor hooks (snake_case CodingKeys, `workspace_roots` defaults to `[]`) |
| `CursorNormalizer` | Core/Models | Converts `CursorHookPayload` → `HookPayload`: maps `workspace_roots[0]`→`cwd`, PascalCase event names, injects `tool="cursor"` |
| `DevEvent` | Core/Models | Persisted event (GRDB `FetchableRecord`/`PersistableRecord`) |
| `DevSession` | Core/Models | Session grouping events by `session_id`. `tool` field: "claude-code" or "cursor" |
| `HookEvent` | Core/Models | Typed enum representation of a hook payload. `stopWindowExpired` is a virtual event injected by `HookStreamCoordinator` when the 2s stop window elapses without a `Notification` |
| `DatabaseManager` | Core/Store | Opens GRDB `DatabasePool`, runs migrations |
| `EventStore` / `SessionStore` | Core/Store | CRUD + pruning. `EventStore.fetchGroupedBySession(sessionIds:limit:in:)` fetches ≤5 undismissed non-background events per session. Always use typed GRDB queries, never raw SQL for updates |
| `HookLog` / `HookLogStore` | Core/Models + Core/Store | Debug audit log: one row per incoming HTTP request, inserted before any business logic. Fields: `hookEventName`, `sessionId`, `notificationType`, `rawPayload` (true raw JSON), `receivedAt`. Parse failures stored with `hookEventName = "PARSE_ERROR"`. Pruned by same `retentionDays` as events |
| `HookEventClassifier` | Core/Services | Pure `HookPayload → HookEvent?` classifier. Returns `nil` for unrecognised hook names (caller silently ignores) |
| `SessionStateReducer` | Core/Services | Pure reducer: `(SessionMachineState, HookEvent) → (SessionMachineState, [Action])`. 13 rules covering all session state transitions. No I/O |
| `SessionMachineState` | Core/Services | In-memory state per session: `status`, `stopWindowActive`, `dbSessionExists`, `cwd`, `tool`. Stale/completed sessions are excluded from `restoreStates` (start from `.initial` if they receive new events) |
| `HookStreamCoordinator` | Core/Services | Actor that drives the pipeline: calls classifier → reducer → executes `[Action]` (DB writes, stop window tasks). Maintains per-session `SessionMachineState` in memory |
| `SessionFileWatcher` | Core/Services | Polls `~/.claude/projects/` JSONL files every 3s. Tracks per-file byte offset to read only new lines. Skips `subagents/` subdirectories. Controlled by `fileWatcherEnabled` UserDefaults key |
| `JournalEventNormalizer` | Core/Services | Maps JSONL entries to `HookPayload`. Only 4 entry types produce payloads (see event flow above); all others return nil |
| `NotificationBatcher` | Core/Services | Per-session batching (>3 events/2s) + global throttle (5/10s) |
| `AuthTokenService` | Core/Services | Generates and persists a 32-byte hex token at `~/.agentpilot/token` (0600) |
| `HookInstaller` | Core/Services | Embeds `notify.sh` and `cursor-notify.sh` scripts; writes to `~/.agentpilot/hooks/`. `claudeCodePrompt()` and `cursorAgentPrompt()` generate hook registration prompts |
| `EventServer` | Server | Hummingbird app builder. `buildApp()` for tests, `start()` for production. `configureRoutes` registers `/event` and `/cursor-event` |
| `AuthMiddleware` | Server | Bearer token validation. `/health` bypasses auth |
| `AppState` | App | `@Observable` root object. Owns DB, server task, batcher, stale timer |
| `PopoverViewModel` | App/ViewModels | Single atomic `ValueObservation` populates `activeSessions: [DevSession]` (idle+busy+waiting, startedAt desc) and `eventsBySession: [String: [DevEvent]]` together. Also keeps `activeSessionCount`/`sessionStartTimes` for backward compat |
| `SessionPanelViewModel` | App/ViewModels | Separate `ValueObservation` for the session panel, splits all sessions into `activeSessions`, `completedSessions`, `staleSessions` |
| `FloatWindowController` | App/FloatWindow | Owns the floating `NSPanel`; drives `hidden/compact/hover/expanded` state machine. Reacts to `PopoverViewModel` changes and mouse tracking. `toggleHoverLock()` flips `isHoverLocked` and immediately upgrades compact→hover |
| `FloatWindowDisplayState` | App/FloatWindow | `@Observable` bridge: `mode`, `contentHeight`, and `isHoverLocked` (persisted to UserDefaults key `floatWindowHoverLocked`) |
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

- SQLite via GRDB, WAL mode, stored at `~/Library/Application Support/AgentPilot/db.sqlite`
- Migrations: `v1_initial` → `v2_dismissed` → `v3_session_cwd` → `v4_session_terminal` (`tty`/`terminal_app`) → `v5_session_status` (renames `running`→`idle`, `error`→`completed`) → `v6_event_types` (renames `taskStarted`→`promptSubmitted`, `taskCompleted/taskError`→`agentStopped`) → `v7_session_custom_name` → `v8_hook_logs` (creates `hook_logs` debug table) → `v9_hook_log_endpoint` (adds `endpoint` column) → `v10_hook_log_event_source` (adds `event_source` column)
- Tests use in-memory DB via `DatabaseManager.openInMemoryDatabase()`
- `ValueObservation` closures must always read every table they need to track — an early-return guard that skips a table read will cause that table to be unregistered from the observation

### Auth

Token at `~/.agentpilot/token` (0600 permissions). `notify.sh` reads this token and sends it as `Authorization: Bearer <token>`. The same token is loaded by `AppState.start()` via `AuthTokenService.ensureToken()`.

### Session state machine

States: `idle` (active, no task) | `busy` (executing) | `waiting` (needs user input) | `completed` (SessionEnd received) | `stale` (inactive 30 min)

State transitions computed by `SessionStateReducer.reduce()`, executed by `HookStreamCoordinator`:
- `SessionStart` hook → create session as `.idle`; if completed/stale, reopen to `.idle`
- `SessionEnd` hook → `.completed` (stamps `ended_at`)
- `UserPromptSubmit` hook → `.busy`; all prior events for session auto-dismissed
- `Notification(permissionNeeded)` hook → `.waiting`
- `Stop` hook → starts 2s stop window; window expiry (no `Notification`) → `.idle`; Stop + `Notification` within 2s → `.waiting`
- Any hook on a stale session via `updateSessionStatus` → reopen to the new status (e.g. `.busy` for `UserPromptSubmit`); `SessionStart` on stale/completed → reopen to `.idle` via `upsertSession`
- 60s timer in `AppState` → `.stale` for sessions with no activity for 30 minutes

### Stale session and pruning

- Stale detection: 60-second timer in `AppState.markStaleSessions()`. A session is a candidate if: status is `idle/busy/waiting`, `started_at` > 30 min ago, no `events` row newer than 30 min, **and** no `hook_logs` row newer than 30 min (the hook_logs check prevents false-positives for long tool calls that produce no DevEvents). Candidates with a live TTY (`lsof -t <tty>` exits 0) are kept active.
- When a stale session receives a new hook event, `updateSessionStatus` reopens it (sets status, clears `ended_at`) rather than dropping the update.
- Pruning: lazy, once per day, configurable retention via `UserDefaults` key `retentionDays` (default 30)

### UserDefaults keys

| Key | Default | Purpose |
|-----|---------|---------|
| `serverPort` | 9876 | HTTP server port |
| `retentionDays` | 30 | Event pruning age |
| `soundEnabled` | true | Notification sound |
| `onboardingCompleted` | false | Onboarding gate |
| `floatWindowPositions` | {} | Per-display-config float window positions: `[String: [String: Double]]`. Key = `CGDisplayVendorNumber-CGDisplayModelNumber-CGDisplaySerialNumber` per display, sorted, joined by `\|`. Value = `{x: Double, topY: Double}`. Written on user drag; restored on first show; invalidated if off-screen. |
| `floatWindowHoverLocked` | false | Hover lock: when true, window stays in hover state and never auto-collapses to compact |
| `fileWatcherEnabled` | true | Enable/disable `SessionFileWatcher` (Path 2 event source) |

### notify.sh

Script content is embedded in `HookInstaller.scriptContent` (the canonical source of truth — not in `Resources/`). `HookInstaller.installScript()` writes it to `~/.agentpilot/hooks/notify.sh` (0755), skipping the write if content is unchanged. Fire-and-forget — uses `&` so it never blocks Claude Code. Enforces 64KB payload limit via `head -c 65536`. If the app is not running, events are silently dropped.

Claude Code hooks registered: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Notification`. Use `HookInstaller.claudeCodePrompt()` to generate the settings.json merge prompt.

### cursor-notify.sh

Script content is embedded in `HookInstaller.cursorScriptContent`. `HookInstaller.installCursorScript()` writes it to `~/.agentpilot/hooks/cursor-notify.sh` (0755). Posts to `/cursor-event` endpoint. Respects `$AGENT_PILOT_PORT` env var (defaults to 9876). Fire-and-forget — never blocks Cursor.

Cursor hooks registered: `sessionStart`, `sessionEnd`, `stop`. Use `HookInstaller.cursorAgentPrompt()` to generate a prompt the user pastes into Cursor Agent, which merges hooks into `~/.cursor/hooks.json`.

### Float window

`FloatWindowController` owns a borderless, always-floating `NSPanel` with its own state machine:
- `hidden` → `compact` (auto, when active sessions + events appear)
- `compact` → `hover` (on mouse enter; shows session rows + toolbar)
- `hover` / `expanded` → `compact` (on mouse exit after 1s delay)
- `compact` / `hover` → `expanded` (on click/tap or notification card tap)
- `expanded` → `compact` / `hidden` (on toggle or mouse exit)

When `isHoverLocked` is true: window skips `compact` entirely (hidden→hover, compact auto-upgrades to hover); mouse exit from `hover` is suppressed; mouse exit from `expanded` still collapses but to `hover` instead of `compact`; `toggleExpanded()` also collapses to `hover`.

The panel renders `FloatWindowCompactView` (compact), `FloatWindowHoverView` (hover), or `MenubarPopover` (expanded). `TrackingView` wraps the content for mouse enter/exit events. Position is persisted per display configuration in `floatWindowPositions` UserDefaults; the top edge is pinned across height changes (only height changes on expand/collapse). On screen configuration change (`NSApplication.didChangeScreenParametersNotification`), the panel is moved to the menubar screen default if the saved position is no longer on any screen.

## Testing patterns

- All store/service tests use `DatabaseManager.openInMemoryDatabase()` — never a file-based DB
- Server tests use `HummingbirdTesting` with `buildApp()` (not `start()`, which binds to a port)
- `HookStreamCoordinator` and `NotificationBatcher` are the highest-risk components for concurrency bugs; test edge cases (rapid events, state reopening, stop window races)
- `SessionStateReducer` is pure (no I/O) — test all 13 rules in isolation via `SessionStateReducerTests`

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

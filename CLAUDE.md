# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Agent Dev Pilot is a macOS menubar app that receives Claude Code hook events via HTTP and surfaces them as native notifications and a popover UI.

### Event flow

```
Claude Code hook → notify.sh → POST /event (port 9876) → EventHandler
  → EventMapper (HookPayload → DevEvent)
  → SessionLifecycleService (persist event, update session state machine)
  → NotificationBatcher (debounce/throttle)
  → NotificationService (UNUserNotificationCenter)
  → AppState publishes to SwiftUI via GRDB ValueObservation
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
| `HookPayload` | Core/Models | Raw JSON from Claude Code hooks |
| `DevEvent` | Core/Models | Persisted event (GRDB `FetchableRecord`/`PersistableRecord`) |
| `DevSession` | Core/Models | Session grouping events by `session_id` |
| `EventMapper` | Core/Models | Maps `HookPayload` → `DevEvent`, infers `EventType` and `AttentionTier` |
| `DatabaseManager` | Core/Store | Opens GRDB `DatabasePool`, runs migrations |
| `EventStore` / `SessionStore` | Core/Store | CRUD + pruning. Always use typed GRDB queries, never raw SQL for updates |
| `SessionLifecycleService` | Core/Services | Session state machine: running/waiting/completed/error/stale |
| `NotificationBatcher` | Core/Services | Per-session batching (>3 events/2s) + global throttle (5/10s) |
| `AuthTokenService` | Core/Services | Generates and persists a 32-byte hex token at `~/.agent-dev-pilot/token` (0600) |
| `EventServer` | Server | Hummingbird app builder. `buildApp()` for tests, `start()` for production |
| `AuthMiddleware` | Server | Bearer token validation. `/health` bypasses auth |
| `AppState` | App | `@Observable` root object. Owns DB, server task, batcher, stale timer |
| `PopoverViewModel` | App/ViewModels | GRDB `ValueObservation` for undismissed events, `actionEvents` + `recentEvents` |

### AttentionTier

| Tier | EventType | UI behavior |
|------|-----------|-------------|
| `.action` | `permissionNeeded` | Red badge, native notification |
| `.review` | `taskCompleted`, `taskError` | Popover list, gray badge |
| `.background` | `taskStarted` | Session panel only |

### Database

- SQLite via GRDB, WAL mode, stored at `~/Library/Application Support/AgentDevPilot/db.sqlite`
- Migrations: `v1_initial` (sessions + events tables + indexes), `v2_dismissed` (adds `is_dismissed` to events)
- Tests use in-memory DB via `DatabaseManager.openInMemoryDatabase()`

### Auth

Token at `~/.agent-dev-pilot/token` (0600 permissions). `notify.sh` reads this token and sends it as `Authorization: Bearer <token>`. The same token is loaded by `AppState.start()` via `AuthTokenService.ensureToken()`.

### Session state machine

State transitions driven by `EventType` inside `SessionLifecycleService.processEvent()`:
- `taskStarted` → `running`
- `permissionNeeded` → `waiting`
- `taskCompleted` → `completed` (stamps `ended_at`)
- `taskError` → `error` (stamps `ended_at`)
- Any event on a completed/error session → reopen to `running`
- 60s timer in `AppState` calls `SessionStore.markStaleSessions(olderThan: 30*60)` → `stale`

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

### notify.sh

Installed at `~/.agent-dev-pilot/hooks/notify.sh` (or sourced from `Resources/notify.sh`). Fire-and-forget — uses `&` so it never blocks Claude Code. Enforces 64KB payload limit via `head -c 65536`. If the app is not running, events are silently dropped.

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

# TODOS

## FloatWindow

### collapseTimer scheduled on .default run loop mode

**Priority:** P2
**Component:** FloatWindow / FloatWindowController

`collapseTimer` is created with `Timer.scheduledTimer(withTimeInterval:...)` which schedules on `.default` run loop mode. When the user is actively moving the mouse, AppKit runs in `.eventTracking` mode and the timer will not fire until mouse movement stops. The 1-second collapse delay can become unbounded if the user is hovering and moving the mouse continuously before exiting the panel.

**Fix:** Create the timer manually and add it with `RunLoop.main.add(timer, forMode: .common)`.

**File:** `Sources/App/FloatWindow/FloatWindowController.swift` — `scheduleCollapse()`
**Found by:** adversarial review on 2026-04-03 (branch: fix/float-window-height-review)

---

## Cursor Integration


### tool field validation on /event endpoint

**Priority:** P3
**Component:** Server/EventHandler

`HookPayload.tool` is decoded from the raw POST body. Any localhost process with a valid token can inject `"tool": "cursor"` into a Claude Code `/event` request and mis-tag the session. The default `notify.sh` doesn't set this field (so it defaults to "claude-code"), but there is no server-side allowlist validation. An unexpected tool value (e.g. "vscode") silently falls through to `default: return nil` in `sessionToolBadge` and is never surfaced.

**Fix:** Validate `tool` against an allowlist `["claude-code", "cursor"]` in `postEvent`. Unknown values should be coerced to `"claude-code"` with a HookLog warning.

**File:** `Sources/Server/EventHandler.swift`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### postEvent / postCursorEvent pipeline duplication

**Priority:** P3
**Component:** Server/EventHandler

The two handlers share ~60 lines of near-identical logic (body collection, parse, HookLog, lifecycle routing, stop window, onEvent). Any future change (new HookLog fields, error enrichment, new event types) must be applied to both. Already diverging: comments removed from `postEvent` in this diff.

**Fix:** Extract a `processParsedPayload(decoded:, db:, stopWindow:, onEvent:)` internal helper. Both handlers call it after their respective parsing step.

**File:** `Sources/Server/EventHandler.swift`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### ~~StopWindowService: timer may fire after SessionEnd (race condition)~~

**Superseded by:** feat/hook-stream-experiment (2026-04-07)
`StopWindowService` and `SessionLifecycleService` were removed entirely and replaced by `HookStreamCoordinator` + `SessionStateReducer`. The new pipeline handles stop window cancellation via `.cancelStopWindow` actions dispatched by the reducer on `SessionEnd`. Verify the equivalent race is covered by `HookStreamCoordinatorTests` if needed.

---

### hook_logs: inconsistent hookEventName casing between Claude Code and Cursor paths

**Priority:** P3
**Component:** Server/EventHandler, Core/Models/HookLog

Claude Code hooks log PascalCase names (`"Stop"`, `"SessionStart"`) because `HookPayload` carries them already normalized. Cursor hooks log camelCase names (`"stop"`, `"sessionStart"`) because the `HookLog` is written from the raw `CursorHookPayload` *before* `CursorNormalizer.normalize()` is called. Any tooling or debugging workflow that queries `hook_logs` by `hookEventName` must know which path produced the row.

**Fix:** Either log the normalized name for Cursor (move HookLog insertion after `normalize()`) or add a `source` column to `hook_logs` (`"claude-code"` / `"cursor"`) so queries can filter appropriately. The latter preserves the "raw before normalization" audit intent.

**File:** `Sources/Server/EventHandler.swift` — `postCursorEvent`, `Sources/Core/Models/HookLog.swift`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### cursor-notify.sh: stdin pipe assumption needs live Cursor verification

**Priority:** P2
**Component:** Core/Services/HookInstaller (cursor-notify.sh)

`cursor-notify.sh` reads the hook payload from stdin via `stdin_data=$(cat)`. This pattern works for Claude Code hooks (which pipe JSON over stdin). Cursor's hook invocation contract is not verified — if Cursor calls the script without piping JSON (or pipes it differently), `stdin_data` will be empty and the POST body will be `{}`, resulting in a PARSE_ERROR log entry. No live Cursor testing has been done.

**Fix:** Verify with a real Cursor installation. Add a fallback: if `stdin_data` is empty, log the absence and exit 0 silently rather than POSTing an empty body. Consider adding a `cursor_hook_test.sh` smoke test that simulates the Cursor invocation pattern.

**File:** `Sources/Core/Services/HookInstaller.swift` — `cursorScriptContent`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### cursor-notify.sh: tilde in hook path may not expand in Cursor hook invocation

**Priority:** P2
**Component:** Core/Services/HookInstaller (cursor-notify.sh), HookInstaller.cursorAgentPrompt()

`HookInstaller.cursorAgentPrompt()` instructs Cursor Agent to register the hook as `~/.agent-dev-pilot/hooks/cursor-notify.sh`. Tilde expansion is a shell feature — if Cursor invokes hooks without a shell (e.g. via `execve` directly), the literal string `~/.agent-dev-pilot/hooks/cursor-notify.sh` will fail with "file not found". This is untested with a real Cursor installation.

**Fix:** Use the absolute path (`/Users/<username>/.agent-dev-pilot/hooks/cursor-notify.sh`) in the hook registration prompt. `HookInstaller.cursorAgentPrompt()` can expand `~` via `FileManager.default.homeDirectoryForCurrentUser` at generation time.

**File:** `Sources/Core/Services/HookInstaller.swift` — `cursorAgentPrompt()`
**Found by:** adversarial review on 2026-04-03 (branch: feat/cursor-integration)

---

### isProgrammaticResize flag is not ref-counted — overlapping animations can corrupt persisted position

**Priority:** P3
**Component:** FloatWindow / FloatWindowController

`isProgrammaticResize` is a plain `Bool`. If two `positionPanel(animated: true)` calls overlap (e.g., `updateFromViewModel` and `handleScreenParametersChanged` fire within 200ms), the first animation's `completionHandler` clears the flag while the second animation is still running. `windowDidMove` then fires with the flag `false` and writes an intermediate animation frame to UserDefaults.

**Fix:** Replace the `Bool` with a nesting counter (`isProgrammaticResizeCount: Int`). Increment before each animated call, decrement in the completion handler. Guard as `count > 0`.

**File:** `Sources/App/FloatWindow/FloatWindowController.swift` — `positionPanel`, `isProgrammaticResize`
**Found by:** adversarial review on 2026-04-05 (branch: feat/float-window-position-persist)

---

### floatWindowPositions UserDefaults dict grows unbounded; no schema versioning

**Priority:** P3
**Component:** FloatWindow / FloatWindowController

`floatWindowPositions` accumulates one entry per unique display configuration encountered (home, office, conference room, client screens). Entries are never pruned. More critically, there is no schema version field — if the position format changes in a future release, old entries silently match the `if let savedX = entry["x"]` check and return semantically wrong coordinates.

**Fix:** Cap at e.g. 20 entries (LRU eviction by access timestamp), or add a top-level `version` key. Write a migration path in `positionPanel`'s first-show branch.

**File:** `Sources/App/FloatWindow/FloatWindowController.swift` — `positionPanel`, `windowDidMove`
**Found by:** adversarial review on 2026-04-05 (branch: feat/float-window-position-persist)

---

## Completed

### HookInstaller: installCursorScript() 调用时机

**Resolved by:** feat/cursor-onboarding (2026-04-05)
`installCursorScript()` 现在在 `AppState.start()` 自动调用（与 Claude Code 脚本并列）。OnboardingView 和 SettingsView 均已加入 Cursor Hooks 区域，展示状态、独立安装按钮、及 `cursorAgentPrompt()` 复制入口。

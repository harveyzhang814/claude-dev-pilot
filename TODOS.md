# TODOS

## FloatWindow

### windowDidMove fires during programmatic animation

**Priority:** P2
**Component:** FloatWindow / FloatWindowController

`windowDidMove` is called by AppKit on every animated frame step, not just on user drags. There is no guard distinguishing a user drag from a programmatic `panel.animator().setFrame(...)` call. As a result, every animated resize (compact→expanded, content height change) writes the intermediate frame's `maxY` to `pinnedTopY` and persists it to `UserDefaults`. On next launch or next transition, the panel can snap to a wrong Y position.

**Fix:** Set an `isProgrammaticResize: Bool` flag before calling `positionPanel(height:animated:)` and clear it in a `NSAnimationContext.completionHandler`. In `windowDidMove`, skip the handler when `isProgrammaticResize == true`.

**File:** `Sources/App/FloatWindow/FloatWindowController.swift` — `windowDidMove` and `positionPanel`
**Found by:** adversarial review on 2026-04-03 (branch: fix/float-window-height-review)

---

### collapseTimer scheduled on .default run loop mode

**Priority:** P2
**Component:** FloatWindow / FloatWindowController

`collapseTimer` is created with `Timer.scheduledTimer(withTimeInterval:...)` which schedules on `.default` run loop mode. When the user is actively moving the mouse, AppKit runs in `.eventTracking` mode and the timer will not fire until mouse movement stops. The 1-second collapse delay can become unbounded if the user is hovering and moving the mouse continuously before exiting the panel.

**Fix:** Create the timer manually and add it with `RunLoop.main.add(timer, forMode: .common)`.

**File:** `Sources/App/FloatWindow/FloatWindowController.swift` — `scheduleCollapse()`
**Found by:** adversarial review on 2026-04-03 (branch: fix/float-window-height-review)

---

## Cursor Integration

### HookInstaller: installCursorScript() 调用时机

**Priority:** P2
**Component:** Core/Services/HookInstaller, App/Settings

目前 `installCursorScript()` 已定义但没有任何地方调用它。何时安装 Cursor hook 脚本尚未决定：随 Claude Code hook 一起安装（Settings 一次完成），还是独立的 Cursor onboarding 入口。

**影响：** 决定会影响 Settings 页面 UI 设计——是一个统一的 "Install All Hooks" 按钮，还是两个独立的安装入口。

**当前状态：** MVP 实现中暂时不调用；脚本存在于 `~/.agent-dev-pilot/hooks/cursor-notify.sh` 但需要用户手动触发或随 Claude Code 安装一起处理。

**建议下一步：** 实现 Settings UI 时决定是否合并。参考 `HookInstaller.installScript()` 的调用位置作为参照。
**File:** `Sources/Core/Services/HookInstaller.swift`, `Sources/App/Views/Settings`
**Found by:** /plan-eng-review on 2026-04-03 (branch: staging, Cursor integration design)

---

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

## Completed

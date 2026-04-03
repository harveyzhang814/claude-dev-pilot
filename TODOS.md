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

## Completed

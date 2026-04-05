# Menubar Tap → Reveal Float Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Float Window mode, clicking the Menu Bar icon reveals the window without forcing it into `.expanded` state; if the window is already visible, a blue border pulse animation hints the user to its location.

**Architecture:** Add `isPulsing: Bool` to `FloatWindowDisplayState` as the controller→view signal. Replace `toggleExpanded()` with `reveal()` in `FloatWindowController` — hidden→show, visible→pulse. Add a shape-matched strokeBorder overlay to `FloatWindowRootView` that animates on `isPulsing`.

**Tech Stack:** SwiftUI (`withAnimation`, `.overlay`, `.strokeBorder`), AppKit (`NSPanel`), Swift Concurrency (`Task.sleep`)

---

## File Map

| File | Change |
|---|---|
| `Sources/App/FloatWindow/FloatWindowDisplayState.swift` | Add `isPulsing: Bool = false` |
| `Sources/App/FloatWindow/FloatWindowController.swift` | Replace `toggleExpanded()` with `reveal()` + add `triggerPulse()` |
| `Sources/App/AppState.swift` | Rename `toggleFloatWindowExpanded()` → `revealFloatWindow()` |
| `Sources/App/AgentDevPilotApp.swift` | Update `FloatWindowMenubarTap` call site |

No new files. No test files — this feature is UI/animation-only with no testable pure logic; the behavior change is covered by existing simulator/manual testing.

---

### Task 1: Add `isPulsing` to `FloatWindowDisplayState`

**Files:**
- Modify: `Sources/App/FloatWindow/FloatWindowDisplayState.swift`

**Current file content (full):**
```swift
// Sources/App/FloatWindow/FloatWindowDisplayState.swift
import Foundation

@MainActor
@Observable
final class FloatWindowDisplayState {
    enum Mode { case hidden, compact, hover, expanded }
    var mode: Mode = .hidden
    var contentHeight: CGFloat = 0
    var isHoverLocked: Bool = UserDefaults.standard.bool(forKey: "floatWindowHoverLocked") {
        didSet { UserDefaults.standard.set(isHoverLocked, forKey: "floatWindowHoverLocked") }
    }
}
```

- [ ] **Step 1: Add `isPulsing` property**

Replace the file content with:

```swift
// Sources/App/FloatWindow/FloatWindowDisplayState.swift
import Foundation

@MainActor
@Observable
final class FloatWindowDisplayState {
    enum Mode { case hidden, compact, hover, expanded }
    var mode: Mode = .hidden
    /// Reported by the SwiftUI content via GeometryReader after each render.
    var contentHeight: CGFloat = 0
    /// When true, the window stays in hover state and never auto-collapses to compact.
    var isHoverLocked: Bool = UserDefaults.standard.bool(forKey: "floatWindowHoverLocked") {
        didSet { UserDefaults.standard.set(isHoverLocked, forKey: "floatWindowHoverLocked") }
    }
    /// Set to true by FloatWindowController when the menubar icon is tapped while
    /// the window is already visible. Drives the border pulse animation in FloatWindowRootView.
    var isPulsing: Bool = false
}
```

- [ ] **Step 2: Build to verify no errors**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/App/FloatWindow/FloatWindowDisplayState.swift
git commit -m "feat: add isPulsing state to FloatWindowDisplayState"
```

---

### Task 2: Replace `toggleExpanded()` with `reveal()` + `triggerPulse()` in `FloatWindowController`

**Files:**
- Modify: `Sources/App/FloatWindow/FloatWindowController.swift` (lines 14–31, the `toggleExpanded` method)

- [ ] **Step 1: Replace `toggleExpanded()` with `reveal()` and add `triggerPulse()`**

Find and replace the existing `toggleExpanded()` method (lines 14–31):

```swift
// BEFORE — remove this entire method:
func toggleExpanded() {
    switch currentState {
    case .hidden:
        transition(to: .expanded)
    case .compact, .hover:
        transition(to: .expanded)
    case .expanded:
        let next: FloatWindowDisplayState.Mode
        if viewModel.activeSessions.isEmpty {
            next = .hidden
        } else if displayState.isHoverLocked {
            next = .hover
        } else {
            next = .compact
        }
        transition(to: next)
    }
}
```

Replace with these two methods:

```swift
/// Called when the user taps the menu bar icon in Float Window mode.
/// Shows the window if hidden; plays a border pulse hint if already visible.
func reveal() {
    switch currentState {
    case .hidden:
        transition(to: displayState.isHoverLocked ? .hover : .compact)
    case .compact, .hover, .expanded:
        triggerPulse()
    }
}

/// Briefly sets isPulsing to drive the border pulse animation in FloatWindowRootView.
/// Resets isPulsing to false before setting true so rapid re-taps restart the animation.
private func triggerPulse() {
    displayState.isPulsing = false
    displayState.isPulsing = true
    Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(0.75))
        self?.displayState.isPulsing = false
    }
}
```

- [ ] **Step 2: Build to verify no errors**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

> Note: `AppState.toggleFloatWindowExpanded()` still calls `floatWindowController?.toggleExpanded()` which no longer exists — the build will show one error here. That's expected; it's fixed in Task 3.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/FloatWindow/FloatWindowController.swift
git commit -m "feat: replace toggleExpanded with reveal + triggerPulse"
```

---

### Task 3: Update `AppState` and `AgentDevPilotApp` call sites

**Files:**
- Modify: `Sources/App/AppState.swift` (the `toggleFloatWindowExpanded` method)
- Modify: `Sources/App/AgentDevPilotApp.swift` (the `FloatWindowMenubarTap` view)

- [ ] **Step 1: Rename method in `AppState`**

In `Sources/App/AppState.swift`, find:

```swift
func toggleFloatWindowExpanded() {
    floatWindowController?.toggleExpanded()
}
```

Replace with:

```swift
func revealFloatWindow() {
    floatWindowController?.reveal()
}
```

- [ ] **Step 2: Update call site in `AgentDevPilotApp`**

In `Sources/App/AgentDevPilotApp.swift`, find in `FloatWindowMenubarTap.body`:

```swift
appState.toggleFloatWindowExpanded()
```

Replace with:

```swift
appState.revealFloatWindow()
```

- [ ] **Step 3: Build to verify clean**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!` with zero errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppState.swift Sources/App/AgentDevPilotApp.swift
git commit -m "feat: wire revealFloatWindow through AppState and FloatWindowMenubarTap"
```

---

### Task 4: Add border pulse overlay to `FloatWindowRootView`

**Files:**
- Modify: `Sources/App/FloatWindow/FloatWindowController.swift` — the `FloatWindowRootView` struct at the bottom of the file (lines ~443–488)

The overlay must be shape-matched to the current mode: `Capsule` for `.compact`, `RoundedRectangle(cornerRadius: 12)` for all others. The overlay sits on top of the content and is invisible (`opacity 0`) when `isPulsing` is false.

- [ ] **Step 1: Add `pulseColor` private property and overlay to `FloatWindowRootView`**

Find the `body` computed property of `FloatWindowRootView`:

```swift
var body: some View {
    content
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onContentHeight(geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in onContentHeight(h) }
            }
        )
}
```

Replace with:

```swift
private var pulseColor: Color {
    Color(red: 0.39, green: 0.70, blue: 0.95)
}

var body: some View {
    content
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onContentHeight(geo.size.height) }
                    .onChange(of: geo.size.height) { _, h in onContentHeight(h) }
            }
        )
        .overlay(pulseOverlay)
}

@ViewBuilder
private var pulseOverlay: some View {
    let active = displayState.isPulsing
    if displayState.mode == .compact {
        Capsule()
            .strokeBorder(pulseColor.opacity(active ? 0.9 : 0), lineWidth: 2)
            .shadow(color: pulseColor.opacity(active ? 0.4 : 0),
                    radius: active ? 8 : 0)
            .animation(.easeOut(duration: 0.7), value: active)
    } else {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(pulseColor.opacity(active ? 0.9 : 0), lineWidth: 2)
            .shadow(color: pulseColor.opacity(active ? 0.4 : 0),
                    radius: active ? 8 : 0)
            .animation(.easeOut(duration: 0.7), value: active)
    }
}
```

- [ ] **Step 2: Build to verify clean**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Run tests to verify nothing regressed**

```bash
swift test 2>&1 | tail -5
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/FloatWindow/FloatWindowController.swift
git commit -m "feat: add border pulse overlay to FloatWindowRootView"
```

---

### Task 5: Manual smoke test + merge

- [ ] **Step 1: Launch the app**

```bash
make run
```

- [ ] **Step 2: Verify reveal behavior**

1. Switch to Float Window mode in Settings (if not already)
2. Wait for the float window to appear in compact or hover state
3. Click the Menu Bar icon → window should **stay in current state** (not expand), and a **blue border pulse** should flash and fade over ~0.7s
4. Click again quickly (before pulse finishes) → pulse should **restart** cleanly
5. Hide the window manually (if possible) or wait for it to go hidden, then click the Menu Bar icon → window should **appear** in compact (or hover if hoverLocked), **no pulse**

- [ ] **Step 3: Merge to staging**

```bash
git checkout staging
git merge feat/menubar-tap-reveal --no-ff -m "feat: menubar tap reveals float window with border pulse"
```

> Create the feature branch first if working from `doc/menubar-tap-reveal-design`:
> ```bash
> git checkout staging
> git checkout -b feat/menubar-tap-reveal
> # then implement Tasks 1–4 on this branch
> ```

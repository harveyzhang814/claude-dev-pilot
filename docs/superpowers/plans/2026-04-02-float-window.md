# Float Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Dynamic Island-style `NSPanel` floating window as a manually-selectable alternative to the existing Menubar Popover display mode.

**Architecture:** `FloatWindowController` (AppKit `NSObject`) owns an `NSPanel` and drives a 3-state machine (hidden/compact/expanded) by observing `PopoverViewModel` via `withObservationTracking`. A `FloatWindowDisplayState` (`@Observable`) bridges the controller to SwiftUI content. `AppState` creates/destroys the controller when the `floatWindowMode` UserDefaults key changes. `SettingsView` exposes a picker to toggle the mode.

**Tech Stack:** AppKit (NSPanel, NSHostingView, NSTrackingArea), SwiftUI, Swift Observation framework

**Worktree:** `.worktrees/feat/float-window` (branch `feat/float-window`)

All commands below assume CWD = `.worktrees/feat/float-window`.

---

## File Map

| File | Action |
|------|--------|
| `Sources/App/FloatWindow/TrackingView.swift` | Create — NSView subclass that forwards mouse enter/exit via callbacks |
| `Sources/App/FloatWindow/FloatWindowDisplayState.swift` | Create — `@Observable` bridge between controller and SwiftUI |
| `Sources/App/FloatWindow/FloatWindowCompactView.swift` | Create — compact SwiftUI content (action/review event cards, no dismiss) |
| `Sources/App/FloatWindow/FloatWindowController.swift` | Create — owns NSPanel, manages state machine, observes PopoverViewModel |
| `Sources/App/AppState.swift` | Modify — add `floatWindowMode`, `setFloatWindowMode(_:)`, `toggleFloatWindowExpanded()` |
| `Sources/App/Views/SettingsView.swift` | Modify — add Display Mode picker section, accept `AppState` param |
| `Sources/App/AgentDevPilotApp.swift` | Modify — pass `appState` to SettingsView; intercept menubar click in Float Window mode |

---

## Task 1: TrackingView + FloatWindowDisplayState + FloatWindowCompactView

**Files:**
- Create: `Sources/App/FloatWindow/TrackingView.swift`
- Create: `Sources/App/FloatWindow/FloatWindowDisplayState.swift`
- Create: `Sources/App/FloatWindow/FloatWindowCompactView.swift`

- [ ] **Step 1: Create `TrackingView.swift`**

```swift
// Sources/App/FloatWindow/TrackingView.swift
import AppKit

/// Transparent NSView that forwards mouse-entered/exited events via callbacks.
final class TrackingView: NSView {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onMouseEnter?() }
    override func mouseExited(with event: NSEvent) { onMouseExit?() }
}
```

- [ ] **Step 2: Create `FloatWindowDisplayState.swift`**

```swift
// Sources/App/FloatWindow/FloatWindowDisplayState.swift
import Foundation

/// @Observable bridge owned by FloatWindowController.
/// SwiftUI views read this to know what to render.
@MainActor
@Observable
final class FloatWindowDisplayState {
    enum Mode { case hidden, compact, expanded }
    var mode: Mode = .hidden
}
```

- [ ] **Step 3: Create `FloatWindowCompactView.swift`**

```swift
// Sources/App/FloatWindow/FloatWindowCompactView.swift
import SwiftUI
import Core

/// Compact float window content: shows up to 5 unread action/review events.
/// Read-only — no dismiss gesture. Tap anywhere to expand.
struct FloatWindowCompactView: View {
    let events: [DevEvent]
    let onExpand: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.prefix(5))) { event in
                CompactEventRow(event: event)
                if event.id != events.prefix(5).last?.id {
                    Divider().padding(.leading, 13)
                }
            }
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }
}

private struct CompactEventRow: View {
    let event: DevEvent

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tierColor)
                .frame(width: 3)
            HStack(spacing: 8) {
                Image(systemName: tierIcon)
                    .foregroundColor(tierColor)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if !event.project.isEmpty {
                        Text(event.project)
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text(event.title)
                        .font(.callout)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var tierColor: Color {
        switch event.attentionTier {
        case .action:     return .red
        case .review:     return Color(red: 0.4, green: 0.8, blue: 0.4)
        case .background: return .gray
        }
    }

    private var tierIcon: String {
        switch event.type {
        case .permissionNeeded: return "exclamationmark.triangle.fill"
        case .promptSubmitted:  return "arrow.up.circle"
        case .agentStopped:     return "checkmark.circle.fill"
        case .authSuccess:      return "lock.open.fill"
        }
    }
}
```

- [ ] **Step 4: Verify build**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/FloatWindow/
git commit -m "feat: add TrackingView, FloatWindowDisplayState, FloatWindowCompactView"
```

---

## Task 2: FloatWindowController

**Files:**
- Create: `Sources/App/FloatWindow/FloatWindowController.swift`

- [ ] **Step 1: Create `FloatWindowController.swift`**

```swift
// Sources/App/FloatWindow/FloatWindowController.swift
import AppKit
import SwiftUI
import Core

/// Owns the floating NSPanel and drives the hidden/compact/expanded state machine.
@MainActor
final class FloatWindowController: NSObject {

    // MARK: - Public

    let displayState = FloatWindowDisplayState()

    func toggleExpanded() {
        switch currentState {
        case .hidden:
            transition(to: .expanded)
        case .compact:
            transition(to: .expanded)
        case .expanded:
            let next: FloatWindowDisplayState.Mode = viewModel.recentEvents.isEmpty ? .hidden : .compact
            transition(to: next)
        }
    }

    func close() {
        isObserving = false
        collapseTimer?.invalidate()
        collapseTimer = nil
        panel.orderOut(nil)
    }

    // MARK: - Init

    init(viewModel: PopoverViewModel, onFocusSession: @escaping (DevSession) -> Void) {
        self.viewModel = viewModel
        self.onFocusSession = onFocusSession

        // Build panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.panel = panel

        super.init()

        setupContentView()
        startObserving()
    }

    // MARK: - Private state

    private enum State { case hidden, compact, expanded }

    private let panel: NSPanel
    private let viewModel: PopoverViewModel
    private let onFocusSession: (DevSession) -> Void
    private var currentState: State = .hidden
    private var collapseTimer: Timer?
    private var isObserving = true
    private var hostingView: NSHostingView<FloatWindowRootView>!

    // MARK: - Setup

    private func setupContentView() {
        let root = FloatWindowRootView(
            displayState: displayState,
            viewModel: viewModel,
            onExpand: { [weak self] in self?.transition(to: .expanded) },
            onFocusSession: onFocusSession
        )
        hostingView = NSHostingView(rootView: root)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let trackingView = TrackingView()
        trackingView.onMouseEnter = { [weak self] in self?.handleMouseEnter() }
        trackingView.onMouseExit  = { [weak self] in self?.handleMouseExit() }

        panel.contentView = trackingView
        trackingView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: trackingView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trackingView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: trackingView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: trackingView.bottomAnchor),
        ])
    }

    // MARK: - State machine

    private func transition(to newMode: FloatWindowDisplayState.Mode) {
        let newState: State
        switch newMode {
        case .hidden:   newState = .hidden
        case .compact:  newState = .compact
        case .expanded: newState = .expanded
        }

        currentState = newState
        displayState.mode = newMode

        if newState == .hidden {
            panel.orderOut(nil)
            return
        }

        let height = targetHeight(for: newState)
        positionPanel(height: height, animated: panel.isVisible)

        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func targetHeight(for state: State) -> CGFloat {
        switch state {
        case .hidden:   return 1
        case .compact:
            let count = min(max(viewModel.recentEvents.count, 1), 5)
            return CGFloat(count) * 52
        case .expanded: return 480
        }
    }

    private func positionPanel(height: CGFloat, animated: Bool) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = screen.frame.midX - 180
        let y = visible.maxY - height
        let newFrame = NSRect(x: x, y: y, width: 360, height: height)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    // MARK: - ViewModel observation

    private func startObserving() {
        withObservationTracking {
            guard isObserving else { return }
            let hasSessions = !viewModel.activeSessions.isEmpty
            let hasEvents   = !viewModel.recentEvents.isEmpty
            updateFromViewModel(hasSessions: hasSessions, hasEvents: hasEvents)
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.startObserving()
            }
        }
    }

    private func updateFromViewModel(hasSessions: Bool, hasEvents: Bool) {
        switch currentState {
        case .hidden:
            if hasSessions && hasEvents { transition(to: .compact) }
        case .compact:
            if !hasEvents || !hasSessions {
                transition(to: .hidden)
            } else {
                // Re-size if event count changed
                let h = targetHeight(for: .compact)
                positionPanel(height: h, animated: true)
            }
        case .expanded:
            // Don't auto-collapse while expanded; if everything clears, hide
            if !hasSessions && !hasEvents { transition(to: .hidden) }
        }
    }

    // MARK: - Mouse tracking

    private func handleMouseEnter() {
        cancelCollapseTimer()
        if currentState == .compact { transition(to: .expanded) }
    }

    private func handleMouseExit() {
        if currentState == .expanded { scheduleCollapse() }
    }

    private func scheduleCollapse() {
        cancelCollapseTimer()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentState == .expanded else { return }
                let next: FloatWindowDisplayState.Mode = self.viewModel.recentEvents.isEmpty ? .hidden : .compact
                self.transition(to: next)
            }
        }
    }

    private func cancelCollapseTimer() {
        collapseTimer?.invalidate()
        collapseTimer = nil
    }
}

// MARK: - FloatWindowRootView

/// Root SwiftUI view hosted inside the NSPanel.
/// Observes FloatWindowDisplayState + PopoverViewModel and renders the correct content.
private struct FloatWindowRootView: View {
    let displayState: FloatWindowDisplayState
    let viewModel: PopoverViewModel
    let onExpand: () -> Void
    let onFocusSession: (DevSession) -> Void

    var body: some View {
        switch displayState.mode {
        case .hidden:
            Color.clear.frame(width: 1, height: 1)
        case .compact:
            FloatWindowCompactView(
                events: Array(viewModel.recentEvents.prefix(5)),
                onExpand: onExpand
            )
        case .expanded:
            MenubarPopover(
                viewModel: viewModel,
                onFocusSession: onFocusSession
            )
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/App/FloatWindow/FloatWindowController.swift
git commit -m "feat: add FloatWindowController with 3-state machine"
```

---

## Task 3: AppState integration

**Files:**
- Modify: `Sources/App/AppState.swift`

- [ ] **Step 1: Add `floatWindowController`, `focusSessionHandler`, and public methods to `AppState`**

In `Sources/App/AppState.swift`, add after the `private var staleTimer: Timer?` line:

```swift
    // Float window
    private var floatWindowController: FloatWindowController?
    /// Set by AgentDevPilotApp at startup; used as the onFocusSession callback for FloatWindowController.
    var focusSessionHandler: ((DevSession) -> Void)?
```

Then add these three methods before the closing `}` of `AppState`:

```swift
    // MARK: - Float Window

    var floatWindowMode: Bool {
        UserDefaults.standard.bool(forKey: "floatWindowMode")
    }

    func setFloatWindowMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "floatWindowMode")
        if enabled {
            let handler = focusSessionHandler ?? { _ in }
            let controller = FloatWindowController(
                viewModel: popoverViewModel,
                onFocusSession: handler
            )
            floatWindowController = controller
        } else {
            floatWindowController?.close()
            floatWindowController = nil
        }
    }

    func toggleFloatWindowExpanded() {
        floatWindowController?.toggleExpanded()
    }
```

Also update `start()` — at the end of the method (just before `await startServer()`), add:

```swift
        // Restore float window mode if previously enabled
        if floatWindowMode {
            setFloatWindowMode(true)
        }
```

- [ ] **Step 2: No import changes needed**

`AppState.swift` doesn't need AppKit imports — `FloatWindowController` (AppKit code) lives in its own file.

- [ ] **Step 3: Verify build**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/App/AppState.swift
git commit -m "feat: integrate FloatWindowController into AppState"
```

---

## Task 4: Settings UI

**Files:**
- Modify: `Sources/App/Views/SettingsView.swift`

- [ ] **Step 1: Add `appState` parameter and Display Mode section to `SettingsView`**

Replace the struct declaration line:

```swift
struct SettingsView: View {
    @AppStorage("serverPort") private var serverPort: Int = 9876
```

with:

```swift
struct SettingsView: View {
    let appState: AppState
    @AppStorage("serverPort") private var serverPort: Int = 9876
```

Add `@AppStorage("floatWindowMode")` after the existing `@AppStorage` lines:

```swift
    @AppStorage("floatWindowMode") private var floatWindowMode: Bool = false
```

Add a new `Section("Display")` block inside `Form { }`, before the `Section("Server")` block:

```swift
            Section("Display") {
                Picker("Mode", selection: $floatWindowMode) {
                    Text("Menubar Popover").tag(false)
                    Text("Float Window").tag(true)
                }
                .pickerStyle(.inline)
                .onChange(of: floatWindowMode) { _, newValue in
                    appState.setFloatWindowMode(newValue)
                }
            }
```

- [ ] **Step 2: Verify build**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!` (will fail if AgentDevPilotApp doesn't yet pass `appState` — that's fine, fix in next task)

If build fails with "missing argument `appState`" in `AgentDevPilotApp.swift`, proceed to Task 5 before verifying.

- [ ] **Step 3: Commit after Task 5 fixes the call site** (combined commit below)

---

## Task 5: AgentDevPilotApp wiring

**Files:**
- Modify: `Sources/App/AgentDevPilotApp.swift`

- [ ] **Step 1: Pass `appState` to `SettingsView`, set `focusSessionHandler`, and handle Float Window mode menubar click**

In `AgentDevPilotApp.swift`, add a `.task` that sets `focusSessionHandler` on `appState`. Replace the `@State private var appState` declaration and `body` with:

```swift
    @State private var appState: AppState = AppState()
```

(unchanged — keep as is)

Replace the entire `body` in `AgentDevPilotApp.swift` with:

```swift
    var body: some Scene {
        MenuBarExtra {
            Group {
                if appState.showOnboarding {
                    OnboardingView {
                        appState.completeOnboarding()
                    }
                } else if appState.floatWindowMode {
                    FloatWindowMenubarTap(appState: appState)
                } else {
                    MenubarPopover(
                        viewModel: appState.popoverViewModel,
                        onFocusSession: { session in
                            focusSession(session)
                        }
                    )
                }
            }
        } label: {
            Group {
                if appState.popoverViewModel.actionCount > 0 {
                    Image(systemName: "bell.badge.fill")
                } else {
                    Image(systemName: "bell.fill")
                }
            }
            .task {
                // Register focus handler before start() so FloatWindowController
                // receives it when floatWindowMode is restored.
                appState.focusSessionHandler = { session in focusSession(session) }
                await appState.start()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Sessions", id: "session-panel") {
            SessionPanelView(
                viewModel: appState.sessionPanelViewModel,
                onFocusSession: { session in
                    focusSession(session)
                }
            )
        }
        .defaultSize(width: 400, height: 500)

        Settings {
            SettingsView(appState: appState)
        }
    }
```

- [ ] **Step 2: Add `FloatWindowMenubarTap` view at the bottom of the file** (before the `focusSession` function)

```swift
/// In Float Window mode, tapping the menubar icon toggles the float window's
/// expanded state. This view closes the MenuBarExtra popup immediately.
private struct FloatWindowMenubarTap: View {
    let appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                appState.toggleFloatWindowExpanded()
                // Close the MenuBarExtra popup that just opened
                NSApplication.shared.keyWindow?.orderOut(nil)
            }
    }
}
```

- [ ] **Step 3: Verify build**

```bash
swift build -c debug 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 4: Run tests**

```bash
swift test 2>&1 | tail -5
```

Expected: `Test run with 93 tests in 15 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Views/SettingsView.swift Sources/App/AgentDevPilotApp.swift
git commit -m "feat: wire Float Window mode toggle into Settings and menubar icon"
```

---

## Task 6: Manual smoke test

- [ ] **Step 1: Build and launch**

```bash
cd ../..   # back to repo root
make run
```

- [ ] **Step 2: Verify Menubar Popover mode (default)**
  - App launches, menubar icon visible
  - Clicking icon shows the standard popover
  - Settings window shows "Display → Menubar Popover" selected

- [ ] **Step 3: Switch to Float Window mode**
  - Open Settings → Display → select "Float Window"
  - Standard popover should stop appearing on icon click
  - Float Window panel should be hidden (no active sessions yet)

- [ ] **Step 4: Verify Float Window with a test event**

Send a test event via curl (use the token from `~/.agent-dev-pilot/token`):

```bash
TOKEN=$(cat ~/.agent-dev-pilot/token)
curl -s -X POST http://localhost:9876/event \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "hook_event_name": "Notification",
    "session_id": "test-float-001",
    "cwd": "/tmp/test",
    "tool_name": "permission_prompt",
    "message": "Test float window event"
  }'
```

Expected:
- Compact Float Window appears at top-center of screen
- Shows the permission_needed event card
- Mouse hover → window expands to full MenubarPopover
- Mouse leave (wait 1s) → collapses back to compact
- Clicking menubar icon → expands window
- Dismissing the event card (in expanded state) → window hides when no more events

- [ ] **Step 5: Switch back to Menubar Popover mode**
  - Settings → Display → Menubar Popover
  - Float Window disappears
  - Clicking menubar icon shows standard popover again

- [ ] **Step 6: Final commit (if any fixups needed)**

```bash
git add -p   # stage only intentional changes
git commit -m "fix: float window smoke test fixups"
```

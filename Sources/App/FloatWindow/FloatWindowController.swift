// Sources/App/FloatWindow/FloatWindowController.swift
import AppKit
import SwiftUI
import Core

/// Owns the floating NSPanel and drives the hidden/compact/hover/expanded state machine.
@MainActor
final class FloatWindowController: NSObject, NSWindowDelegate {

    // MARK: - Public

    let displayState = FloatWindowDisplayState()

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

    /// Briefly sets isBorderPulsing to drive the border pulse animation in FloatWindowRootView.
    /// Resets isBorderPulsing to false before setting true so rapid re-taps restart the animation.
    private func triggerPulse() {
        displayState.isBorderPulsing = false
        displayState.isBorderPulsing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.75))
            self?.displayState.isBorderPulsing = false
        }
    }

    func close() {
        isObserving = false
        collapseTimer?.invalidate()
        collapseTimer = nil
        pinnedTopY = nil
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        panel.orderOut(nil)
    }

    func toggleHoverLock() {
        displayState.isHoverLocked.toggle()
        if displayState.isHoverLocked && currentState == .compact {
            transition(to: .hover)
        }
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
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        self.panel = panel

        super.init()

        panel.delegate = self
        setupContentView()
        startObserving()
        startObservingContentHeight()
        NotificationCenter.default.addObserver(self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    // MARK: - Constants

    nonisolated static let maxExpandedHeight: CGFloat = 480
    nonisolated static let minExpandedHeight: CGFloat = 150

    // MARK: - Private state

    private enum State { case hidden, compact, hover, expanded }

    private let panel: NSPanel
    private let viewModel: PopoverViewModel
    private let onFocusSession: (DevSession) -> Void
    private var currentState: State = .hidden
    private var collapseTimer: Timer?
    private var isObserving = true
    private var hostingView: NSHostingView<FloatWindowRootView>!
    /// Top edge of the panel in screen coordinates. Saved across drags so
    /// compact↔expanded transitions only change height, not position.
    private var pinnedTopY: CGFloat?
    /// True while positionPanel is driving an animated or programmatic frame
    /// change. windowDidMove fires on every animation frame — this flag prevents
    /// intermediate positions from being persisted to UserDefaults.
    private var isProgrammaticResize = false

    // MARK: - Setup

    private func setupContentView() {
        let root = FloatWindowRootView(
            displayState: displayState,
            viewModel: viewModel,
            onExpand: { [weak self] in self?.transition(to: .expanded) },
            onToggleLock: { [weak self] in self?.toggleHoverLock() },
            onFocusSession: onFocusSession,
            onContentHeight: { [weak self] h in
                Task { @MainActor [weak self] in self?.displayState.contentHeight = h }
            }
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
        case .hover:    newState = .hover
        case .expanded: newState = .expanded
        }

        currentState = newState

        if newState == .hidden {
            displayState.mode = newMode
            panel.orderOut(nil)
            return
        }

        if newState == .expanded {
            displayState.mode = newMode
            // Start at maxExpandedHeight so SwiftUI can render MenubarPopover at full size.
            // startObservingContentHeight() will resize down once GeometryReader reports
            // the actual content height. Using fittingSize here is unreliable because
            // SwiftUI re-renders asynchronously — fittingSize returns the old compact/hover
            // size, which gets clamped to minExpandedHeight and traps the GeometryReader.
            // No animation on expand — instant appearance feels more responsive.
            positionPanel(height: Self.maxExpandedHeight, animated: false)
            if !panel.isVisible {
                panel.orderFront(nil)
            }
            return
        }

        let height = targetHeight(for: newState)
        // Collapsing (panel shrinks): keep current content visible during the animation,
        // switch displayState.mode only after the animation completes. This prevents the
        // incoming (smaller) view from centering itself in an oversized panel mid-animation
        // and appearing at the wrong position. Applies to hover→compact, expanded→compact,
        // expanded→hover, and any future collapsing transition automatically.
        // Expanding: switch content first so SwiftUI renders at full target size immediately.
        let isCollapsing = panel.isVisible && height < panel.frame.height
        if isCollapsing {
            positionPanel(height: height, animated: true) { [weak self] in
                guard let self, self.currentState == newState else { return }
                self.displayState.mode = newMode
            }
        } else {
            displayState.mode = newMode
            positionPanel(height: height, animated: panel.isVisible)
        }

        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    private func targetHeight(for state: State) -> CGFloat {
        switch state {
        case .hidden:   return 1
        case .compact:
            let count = min(max(viewModel.activeSessions.count, 1), 5)
            return CGFloat(count) * 36
        case .hover:
            let count = min(max(viewModel.activeSessions.count, 1), 5)
            // rows + toolbar: divider(1) + padding-top(2) + padding-vertical(8) + icon(22) = 33, +1 buffer
            return CGFloat(count) * 36 + 34
        case .expanded:
            // Expanded height is driven by fittingSize / GeometryReader — not a fixed value.
            // This case is unreachable; .expanded returns early in transition(to:).
            return Self.maxExpandedHeight
        }
    }

    /// Clamps a SwiftUI-reported height to the allowed expanded range.
    nonisolated static func clampedExpandedHeight(_ h: CGFloat) -> CGFloat {
        guard h > 0 else { return maxExpandedHeight }
        return min(max(h, minExpandedHeight), maxExpandedHeight)
    }

    private func positionPanel(height: CGFloat, animated: Bool, completion: (() -> Void)? = nil) {
        let originX: CGFloat
        let topY: CGFloat

        if let pinned = pinnedTopY {
            // Already positioned (first show done or user dragged) — keep x and top edge.
            originX = panel.frame.origin.x
            topY = pinned
        } else {
            // First show: restore saved position for this display config, or use default.
            guard !NSScreen.screens.isEmpty else { return }
            let key = Self.currentDisplayKey()
            let positions = UserDefaults.standard.dictionary(forKey: "floatWindowPositions")
                as? [String: [String: Double]] ?? [:]
            if let entry = positions[key],
               let savedX = entry["x"], let savedTopY = entry["topY"],
               Self.isPositionVisible(x: savedX, topY: savedTopY, in: NSScreen.screens.map(\.frame)) {
                originX = savedX
                topY = savedTopY
            } else {
                // NSScreen.screens.first is always the screen containing the menu bar (per Apple docs).
                let screen = NSScreen.screens.first ?? NSScreen.main
                guard let screen else { return }
                originX = screen.frame.midX - 180
                topY = screen.visibleFrame.maxY
            }
            pinnedTopY = topY
        }

        let newFrame = NSRect(x: originX, y: topY - height, width: 360, height: height)
        isProgrammaticResize = true
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            } completionHandler: { [weak self] in
                self?.isProgrammaticResize = false
                completion?()
            }
        } else {
            panel.setFrame(newFrame, display: true)
            isProgrammaticResize = false
            completion?()
        }
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, !self.isProgrammaticResize else { return }
            // Update pinnedTopY to the new top edge after user drag.
            self.pinnedTopY = self.panel.frame.maxY
            let key = Self.currentDisplayKey()
            guard !key.isEmpty else { return }
            var positions = UserDefaults.standard.dictionary(forKey: "floatWindowPositions")
                as? [String: [String: Double]] ?? [:]
            positions[key] = ["x": self.panel.frame.origin.x, "topY": self.panel.frame.maxY]
            UserDefaults.standard.set(positions, forKey: "floatWindowPositions")
        }
    }

    // MARK: - Screen change handling

    /// Called when displays are connected, disconnected, or reconfigured.
    /// If the panel is visible but no longer on any screen, moves it back to the
    /// default position on the current menubar screen.
    @objc private func handleScreenParametersChanged() {
        guard panel.isVisible, let currentTopY = pinnedTopY else { return }
        let screenFrames = NSScreen.screens.map(\.frame)
        guard !screenFrames.isEmpty else { return }
        let x = panel.frame.origin.x
        if !Self.isPositionVisible(x: x, topY: currentTopY, in: screenFrames) {
            // Panel is off-screen — reset and re-position on the current menubar screen.
            pinnedTopY = nil
            positionPanel(height: panel.frame.height, animated: true)
        }
    }

    // MARK: - Position persistence helpers

    /// Returns a key identifying the current display configuration.
    /// Format: "vendor-model-serial" per display, sorted, joined by "|".
    /// Uses stable hardware identifiers (CGDisplayVendorNumber, CGDisplayModelNumber,
    /// CGDisplaySerialNumber) rather than the runtime-assigned CGDirectDisplayID.
    /// Displays without burned-in serial numbers return 0, producing key segment "V-M-0".
    nonisolated static func currentDisplayKey() -> String {
        guard !NSScreen.screens.isEmpty else { return "" }
        let displays = NSScreen.screens.compactMap { screen -> (UInt32, UInt32, UInt32)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return nil }
            return (CGDisplayVendorNumber(id), CGDisplayModelNumber(id), CGDisplaySerialNumber(id))
        }
        return displayKey(for: displays.map { (vendor: $0.0, model: $0.1, serial: $0.2) })
    }

    /// Formats a display tuple list into a stable config key string.
    /// Extracted as a pure function for unit testing without NSScreen dependency.
    nonisolated static func displayKey(
        for displays: [(vendor: UInt32, model: UInt32, serial: UInt32)]
    ) -> String {
        displays.map { "\($0.vendor)-\($0.model)-\($0.serial)" }.sorted().joined(separator: "|")
    }

    /// Returns true if the window's top strip (top edge at `topY`, width 360, height 36)
    /// intersects at least one of the provided screen frames.
    nonisolated static func isPositionVisible(
        x: CGFloat, topY: CGFloat, in screenFrames: [NSRect]
    ) -> Bool {
        let rect = NSRect(x: x, y: topY - 36, width: 360, height: 36)
        return screenFrames.contains { $0.intersects(rect) }
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

    /// Observes contentHeight reported by SwiftUI's GeometryReader.
    /// Only resizes the panel in .expanded mode — hover/compact use targetHeight formulas
    /// (accurate enough that GeometryReader correction isn't needed there).
    private func startObservingContentHeight() {
        withObservationTracking {
            guard isObserving else { return }
            let h = displayState.contentHeight
            if currentState == .expanded, h > 0 {
                let clamped = Self.clampedExpandedHeight(h)
                if abs(clamped - panel.frame.height) > 1 {
                    // No animation — this correction fires right after expand,
                    // so animating it causes a visible "expand then shrink" jitter.
                    positionPanel(height: clamped, animated: false)
                }
            }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.startObservingContentHeight()
            }
        }
    }

    private func updateFromViewModel(hasSessions: Bool, hasEvents: Bool) {
        switch currentState {
        case .hidden:
            if hasSessions && hasEvents {
                transition(to: displayState.isHoverLocked ? .hover : .compact)
            }
        case .compact:
            if !hasEvents || !hasSessions {
                transition(to: .hidden)
            } else if displayState.isHoverLocked {
                transition(to: .hover)
            } else {
                // Re-size if event count changed
                let h = targetHeight(for: .compact)
                positionPanel(height: h, animated: true)
            }
        case .hover:
            if viewModel.activeSessions.isEmpty {
                transition(to: .hidden)
            } else {
                let h = targetHeight(for: .hover)
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
        if currentState == .compact { transition(to: .hover) }
    }

    private func handleMouseExit() {
        // When locked and in hover, mouse exit has no effect — stay in hover.
        // When locked and in expanded, still collapse (scheduleCollapse resolves to .hover, not .compact).
        if displayState.isHoverLocked && currentState == .hover { return }
        if currentState == .hover || currentState == .expanded { scheduleCollapse() }
    }

    private func scheduleCollapse() {
        cancelCollapseTimer()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving,
                      self.currentState == .hover || self.currentState == .expanded else { return }
                let next: FloatWindowDisplayState.Mode
                if self.viewModel.activeSessions.isEmpty {
                    next = .hidden
                } else if self.displayState.isHoverLocked {
                    next = .hover
                } else {
                    next = .compact
                }
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
    let onToggleLock: () -> Void
    let onFocusSession: (DevSession) -> Void
    let onContentHeight: (CGFloat) -> Void

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

    @ViewBuilder
    private var content: some View {
        switch displayState.mode {
        case .hidden:
            Color.clear.frame(width: 1, height: 1)
        case .compact:
            FloatWindowCompactView(
                sessions: Array(viewModel.activeSessions.prefix(5))
            )
        case .hover:
            FloatWindowHoverView(
                sessions: viewModel.activeSessions,
                eventsBySession: viewModel.eventsBySession,
                onFocusSession: onFocusSession,
                onExpand: onExpand,
                isLocked: displayState.isHoverLocked,
                onToggleLock: onToggleLock
            )
        case .expanded:
            MenubarPopover(
                viewModel: viewModel,
                onFocusSession: onFocusSession
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

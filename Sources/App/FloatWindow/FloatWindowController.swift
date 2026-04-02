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

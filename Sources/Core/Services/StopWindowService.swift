import Foundation
import GRDB

/// Coalesces Stop hook and Notification hook events within a 2-second window
/// to determine the correct session state transition without flickering.
///
/// Rule:
///   - Window receives any Notification (permission_prompt, elicitation_dialog, idle_prompt)
///     → session transitions to `.waiting`
///   - Window receives only Stop, no Notification
///     → session transitions to `.idle`
///
/// Both arrival orders are handled correctly because both events enter the same
/// window and the final state is computed once when the window expires.
public actor StopWindowService {

    private struct WindowEntry {
        var hasNotification: Bool = false
        var timer: Task<Void, Never>?
    }

    private var windows: [String: WindowEntry] = [:]
    private let windowDuration: TimeInterval
    private let db: any DatabaseWriter & Sendable
    private let onIdleResolved: (@Sendable (String) -> Void)?

    public init(
        db: any DatabaseWriter & Sendable,
        windowDuration: TimeInterval = 2.0,
        onIdleResolved: (@Sendable (String) -> Void)? = nil
    ) {
        self.db = db
        self.windowDuration = windowDuration
        self.onIdleResolved = onIdleResolved
    }

    /// Called when a Stop hook arrives for a session.
    public func recordStop(sessionId: String) {
        openWindow(for: sessionId)
    }

    /// Called when a Notification hook (permission_prompt, elicitation_dialog, idle_prompt)
    /// arrives for a session.
    public func recordNotification(sessionId: String) {
        windows[sessionId, default: WindowEntry()].hasNotification = true
        openWindow(for: sessionId)
    }

    // MARK: - Private

    private func openWindow(for sessionId: String) {
        // Cancel any existing timer to reset the window
        windows[sessionId]?.timer?.cancel()
        if windows[sessionId] == nil {
            windows[sessionId] = WindowEntry()
        }
        windows[sessionId]!.timer = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(windowDuration * 1_000_000_000))
            } catch {
                return // Cancelled — a new event reset the window
            }
            await flush(sessionId: sessionId)
        }
    }

    private func flush(sessionId: String) {
        guard let entry = windows.removeValue(forKey: sessionId) else { return }
        let newStatus: SessionStatus = entry.hasNotification ? .waiting : .idle
        try? db.write { db in
            // Only update sessions that are still active; never override completed/stale
            try db.execute(
                sql: """
                    UPDATE sessions SET status = ?
                    WHERE id = ? AND status NOT IN ('completed', 'stale')
                    """,
                arguments: [newStatus.rawValue, sessionId]
            )
            // Only insert the ready card if we actually updated the session row.
            // db.changesCount == 0 means the session was already completed/stale — skip
            // to avoid inserting phantom agentStopped events into closed sessions.
            if newStatus == .idle && db.changesCount > 0 {
                // Persist a review-tier event so the popover shows a green "ready" card
                if let session = try DevSession.fetchOne(db, key: sessionId) {
                    let readyTitle = session.tool == "cursor" ? "Cursor is ready" : "Claude is ready"
                    let event = DevEvent(
                        id: UUID().uuidString,
                        sessionId: sessionId,
                        type: .agentStopped,
                        title: readyTitle,
                        detail: session.cwd,
                        payload: "{}",
                        tokenCount: nil,
                        durationSeconds: nil,
                        timestamp: Date(),
                        attentionTier: .review
                    )
                    try event.insert(db)
                }
            }
        }
        if newStatus == .idle {
            onIdleResolved?(sessionId)
        }
    }
}

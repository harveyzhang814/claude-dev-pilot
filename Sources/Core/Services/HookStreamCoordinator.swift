// Sources/Core/Services/HookStreamCoordinator.swift
import Foundation
import GRDB

public actor HookStreamCoordinator {
    private var states: [String: SessionMachineState] = [:]
    private var stopWindowTasks: [String: Task<Void, Never>] = [:]
    private let db: any DatabaseWriter & Sendable
    private let stopWindowDuration: Duration
    private let onIdleResolved: (@Sendable (String) -> Void)?

    public init(
        db: any DatabaseWriter & Sendable,
        stopWindowDuration: Duration = .seconds(2),
        onIdleResolved: (@Sendable (String) -> Void)? = nil
    ) {
        self.db = db
        self.stopWindowDuration = stopWindowDuration
        self.onIdleResolved = onIdleResolved
    }

    /// Main entry point — call this for every incoming HookPayload.
    public func process(_ payload: HookPayload) async {
        guard let event = HookEventClassifier.classify(payload) else { return }
        let sid = event.sessionId
        var current = states[sid] ?? .initial
        // Capture cwd from any hook, not just SessionStart. This ensures the
        // missed-SessionStart fallback can create a session with the real project
        // directory instead of "unknown" when a pre-existing session sends its
        // first hook after the app starts.
        if current.cwd == nil && !payload.cwd.isEmpty {
            current.cwd = payload.cwd
        }
        let (next, actions) = SessionStateReducer.reduce(current, event)
        states[sid] = next
        await execute(actions)
    }

    /// Restore in-memory state from DB on app startup.
    public func restoreStates(from sessions: [DevSession]) {
        for session in sessions where session.status != .completed && session.status != .stale {
            states[session.id] = SessionMachineState(
                status: session.status,
                stopWindowActive: false,
                dbSessionExists: true,
                cwd: session.cwd,
                tool: session.tool
            )
        }
    }

    // MARK: - Private

    private func execute(_ actions: [Action]) async {
        for action in actions {
            switch action {

            case .startStopWindow(let sid):
                stopWindowTasks[sid]?.cancel()
                let duration = stopWindowDuration
                stopWindowTasks[sid] = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    await self?.injectExpired(sessionId: sid)
                }

            case .cancelStopWindow(let sid):
                stopWindowTasks[sid]?.cancel()
                stopWindowTasks[sid] = nil

            case .upsertSession(let sid, let status, let cwd, let tty, let terminalApp, let tool, _):
                let project = URL(fileURLWithPath: cwd).lastPathComponent
                try? await db.write { db in
                    if var existing = try DevSession.fetchOne(db, key: sid) {
                        existing.cwd = cwd
                        existing.tty = tty
                        existing.terminalApp = terminalApp
                        existing.tool = tool
                        existing.project = project
                        if existing.status == .completed || existing.status == .stale {
                            existing.status = .idle
                            existing.endedAt = nil
                        }
                        try existing.update(db)
                    } else {
                        var session = DevSession(
                            id: sid,
                            project: project,
                            customName: nil,
                            cwd: cwd,
                            tty: tty,
                            terminalApp: terminalApp,
                            tool: tool,
                            status: status,
                            startedAt: Date(),
                            endedAt: nil,
                            totalTokens: nil,
                            lastEventTitle: nil
                        )
                        try session.insert(db)
                    }
                }

            case .updateSessionStatus(let sid, let status):
                let fallbackCwd = states[sid]?.cwd
                let fallbackTool = states[sid]?.tool ?? "claude-code"
                try? await db.write { db in
                    if let existing = try DevSession.fetchOne(db, key: sid) {
                        if existing.status == .stale {
                            // Reopen: new hook activity means the session is live again.
                            // Use raw SQL to avoid DevSession.update(db) re-encoding fields
                            // that may be stored in legacy ISO 8601 format (e.g. ended_at
                            // written as "2026-01-01T00:00:00Z" by old markStale calls),
                            // which GRDB cannot decode as Date and would throw on fetchOne.
                            try db.execute(
                                sql: "UPDATE sessions SET status = ?, ended_at = NULL WHERE id = ?",
                                arguments: [status.rawValue, sid]
                            )
                        } else if existing.status != .completed {
                            try db.execute(
                                sql: "UPDATE sessions SET status = ? WHERE id = ?",
                                arguments: [status.rawValue, sid]
                            )
                        }
                    } else if status != .completed && status != .stale {
                        // SessionStart was missed — create a minimal session.
                        // Only for active statuses: terminal states (completed/stale)
                        // must not create a ghost session for a session we never tracked.
                        let project = fallbackCwd.map {
                            URL(fileURLWithPath: $0).lastPathComponent
                        } ?? "unknown"
                        var session = DevSession(
                            id: sid,
                            project: project,
                            customName: nil,
                            cwd: fallbackCwd,
                            tty: nil,
                            terminalApp: nil,
                            tool: fallbackTool,
                            status: status,
                            startedAt: Date(),
                            endedAt: nil,
                            totalTokens: nil,
                            lastEventTitle: nil
                        )
                        try session.insert(db)
                    }
                }

            case .insertDevEvent(let sid, let type, let title, let cwd, let tier):
                let event = DevEvent(
                    id: UUID().uuidString,
                    sessionId: sid,
                    type: type,
                    title: title,
                    detail: cwd,
                    payload: "{}",
                    tokenCount: nil,
                    durationSeconds: nil,
                    timestamp: Date(),
                    attentionTier: tier
                )
                try? await db.write { db in try event.insert(db) }

            case .dismissPriorEvents(let sid):
                try? await db.write { db in
                    try db.execute(
                        sql: "UPDATE events SET is_dismissed = 1 WHERE session_id = ? AND is_dismissed = 0",
                        arguments: [sid]
                    )
                }
            }
        }
    }

    private func injectExpired(sessionId: String) async {
        stopWindowTasks[sessionId] = nil
        let current = states[sessionId] ?? .initial
        let (next, actions) = SessionStateReducer.reduce(
            current, .stopWindowExpired(sessionId: sessionId)
        )
        states[sessionId] = next
        await execute(actions)
        if next.status == .idle {
            onIdleResolved?(sessionId)
        }
    }
}

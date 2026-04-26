import Foundation
import Combine
import GRDB
import Core

@MainActor
@Observable
public final class PopoverViewModel {
    public var actionEvents: [DevEvent] = []
    public var recentEvents: [DevEvent] = []
    public var actionCount: Int = 0
    public var activeSessionCount: Int = 0
    private(set) var sessionStartTimes: [String: Date] = [:]
    public var activeSessions: [DevSession] = []
    public var eventsBySession: [String: [DevEvent]] = [:]

    /// Sessions sorted by cwd-group then tool priority.
    /// Groups are ordered by the most recent startedAt within the group (newest first).
    /// Within the same cwd: claude-code before cursor, then most recent first.
    public var sortedActiveSessions: [DevSession] {
        activeSessions.sorted { a, b in
            if a.cwd == b.cwd {
                if a.tool != b.tool { return a.tool == "claude-code" }
                return a.startedAt > b.startedAt
            }
            let aMax = activeSessions.filter { $0.cwd == a.cwd }.map(\.startedAt).max() ?? a.startedAt
            let bMax = activeSessions.filter { $0.cwd == b.cwd }.map(\.startedAt).max() ?? b.startedAt
            return aMax > bMax
        }
    }

    /// Deduplication-aware display names keyed by session id.
    ///
    /// Rules:
    /// - Custom name (`/rename` or `-n`): use as-is.
    /// - Single session per (cwd, tool) pair: show just the project name.
    /// - Multiple sessions with the same (cwd, tool): append tty suffix
    ///   (e.g. "agent-dev-pilot · ttys003") so they're distinguishable.
    ///   Tool badge handles cwd-same-but-different-tool disambiguation.
    public var displayNames: [String: String] {
        var cwdToolCount: [String: Int] = [:]
        for session in activeSessions where session.customName == nil {
            let key = "\(session.cwd)|\(session.tool)"
            cwdToolCount[key, default: 0] += 1
        }
        return activeSessions.reduce(into: [:]) { result, session in
            if let name = session.customName {
                result[session.id] = name
            } else {
                let key = "\(session.cwd)|\(session.tool)"
                if (cwdToolCount[key] ?? 0) > 1 {
                    let ttySuffix = session.tty.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                    result[session.id] = ttySuffix.isEmpty ? session.project : "\(session.project) · \(ttySuffix)"
                } else {
                    result[session.id] = session.project
                }
            }
        }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var db: (any DatabaseReader & DatabaseWriter)?

    public init() {}

    public func sessionStartedAt(for sessionId: String) -> Date? { sessionStartTimes[sessionId] }

    public func dismiss(eventId: String) {
        guard let db else { return }
        do {
            try EventStore.dismiss(id: eventId, in: db)
        } catch {
            print("[AgentPilot] dismiss failed for event \(eventId): \(error)")
        }
    }

    public func startObserving(db: any DatabaseReader & DatabaseWriter) {
        self.db = db

        // Observe undismissed action-tier events
        let actionObservation = ValueObservation.tracking { db in
            try DevEvent
                .filter(DevEvent.Columns.attentionTier == AttentionTier.action.rawValue)
                .filter(DevEvent.Columns.isDismissed == false)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(50)
                .fetchAll(db)
        }

        actionObservation
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            // Throttle to at most one update per 150ms. Rapid event add/dismiss cycles
            // (e.g. Claude repeatedly requesting then losing permission) flip actionCount
            // between 0 and >0, which switches the menubar icon between bell.fill and
            // bell.badge.fill. The two icons have different widths, causing the MenuBarExtra
            // popup to reposition horizontally on every flip — the "drift" the user sees.
            // latest:true ensures we always end up with the current value.
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] events in
                    guard let self else { return }
                    self.actionEvents = events
                    self.actionCount = events.count
                }
            )
            .store(in: &cancellables)

        // Observe undismissed non-background events (action + review tiers)
        let recentObservation = ValueObservation.tracking { db in
            try DevEvent
                .filter(DevEvent.Columns.attentionTier != AttentionTier.background.rawValue)
                .filter(DevEvent.Columns.isDismissed == false)
                .order(DevEvent.Columns.timestamp.desc)
                .limit(100)
                .fetchAll(db)
        }

        recentObservation
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] events in
                    self?.recentEvents = events
                }
            )
            .store(in: &cancellables)

        // Single merged observation: active sessions + their grouped events (atomic)
        let activeSessionsAndEventsObservation = ValueObservation.tracking { db -> ([DevSession], [String: [DevEvent]]) in
            let sessions = try DevSession
                .filter([SessionStatus.idle.rawValue, SessionStatus.busy.rawValue, SessionStatus.waiting.rawValue]
                    .contains(DevSession.Columns.status))
                .order(DevSession.Columns.startedAt.desc)
                .fetchAll(db)
            let sessionIds = sessions.map(\.id)
            let grouped = try EventStore.fetchGroupedBySession(sessionIds: sessionIds, in: db)
            return (sessions, grouped)
        }

        activeSessionsAndEventsObservation
            .publisher(in: db, scheduling: .immediate)
            .receive(on: DispatchQueue.main)
            // Throttle: rapid event adds/dismissals (agentStopped → UserPromptSubmit dismiss
            // cycle) continuously change eventsBySession, making MenubarPopover grow and shrink.
            // macOS animates the popup window height change each time, producing the
            // "drift-return" oscillation. Throttle collapses bursts to one update per 150ms
            // while always ending on the latest value.
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { [weak self] (sessions, grouped) in
                    guard let self else { return }
                    self.activeSessions = sessions
                    self.activeSessionCount = sessions.count
                    self.sessionStartTimes = sessions.reduce(into: [:]) { $0[$1.id] = $1.startedAt }
                    self.eventsBySession = grouped
                }
            )
            .store(in: &cancellables)
    }

    public func resetBadge() {
        actionCount = 0
    }

    public func stopObserving() {
        cancellables.removeAll()
    }
}

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

    private var cancellables: Set<AnyCancellable> = []
    private var db: (any DatabaseReader & DatabaseWriter)?

    public init() {}

    public func sessionStartedAt(for sessionId: String) -> Date? { sessionStartTimes[sessionId] }

    public func dismiss(eventId: String) {
        guard let db else { return }
        do {
            try EventStore.dismiss(id: eventId, in: db)
        } catch {
            print("[AgentDevPilot] dismiss failed for event \(eventId): \(error)")
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

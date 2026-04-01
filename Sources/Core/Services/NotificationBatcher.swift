import Foundation

/// Batches notifications to prevent spam.
/// - Per-session: >3 events in 2s → one batched notification.
/// - Global: max 5 notifications per 10s window → summary.
public final class NotificationBatcher: @unchecked Sendable {

    public struct Notification: Sendable {
        public let event: DevEvent?
        public let sessionId: String
        public let eventCount: Int
        public let isBatched: Bool
        public let isSummary: Bool
        public let title: String
        public let body: String
    }

    private let batchThreshold = 3
    private let batchWindowSeconds: TimeInterval = 2.0
    private let globalMaxPerWindow: Int
    private let globalWindowSeconds: TimeInterval = 10.0

    private var pendingEvents: [String: [DevEvent]] = [:]
    private var pendingTimestamps: [String: Date] = [:]
    private var globalNotificationCount = 0
    private var globalWindowStart = Date()

    private let onNotification: (Notification) -> Void

    public init(globalMaxPerWindow: Int = 5, onNotification: @escaping (Notification) -> Void) {
        self.globalMaxPerWindow = globalMaxPerWindow
        self.onNotification = onNotification
    }

    public func submit(_ event: DevEvent) {
        let sid = event.sessionId
        let now = Date()
        if let firstTime = pendingTimestamps[sid], now.timeIntervalSince(firstTime) > batchWindowSeconds {
            flushSession(sid)
        }
        if pendingEvents[sid] == nil {
            pendingEvents[sid] = []
            pendingTimestamps[sid] = now
        }
        pendingEvents[sid]?.append(event)
    }

    public func flush() {
        for sid in Array(pendingEvents.keys) { flushSession(sid) }
    }

    private func flushSession(_ sessionId: String) {
        guard let events = pendingEvents[sessionId], !events.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(globalWindowStart) > globalWindowSeconds {
            globalNotificationCount = 0
            globalWindowStart = now
        }

        if events.count > batchThreshold {
            emitNotification(Notification(
                event: events.last, sessionId: sessionId, eventCount: events.count,
                isBatched: true, isSummary: false,
                title: "\(events.count) events from \(projectName(events.first))",
                body: "Latest: \(events.last?.title ?? "unknown")"
            ))
        } else {
            for event in events {
                emitNotification(Notification(
                    event: event, sessionId: sessionId, eventCount: 1,
                    isBatched: false, isSummary: false,
                    title: event.title, body: event.detail ?? ""
                ))
            }
        }
        pendingEvents[sessionId] = nil
        pendingTimestamps[sessionId] = nil
    }

    private func emitNotification(_ notification: Notification) {
        globalNotificationCount += 1
        if globalNotificationCount > globalMaxPerWindow {
            onNotification(Notification(
                event: nil, sessionId: "", eventCount: globalNotificationCount,
                isBatched: false, isSummary: true,
                title: "\(globalNotificationCount) events across multiple projects",
                body: "Open Agent Dev Pilot to see details"
            ))
        } else {
            onNotification(notification)
        }
    }

    private func projectName(_ event: DevEvent?) -> String {
        guard let detail = event?.detail else { return "unknown" }
        return URL(fileURLWithPath: detail).lastPathComponent
    }
}

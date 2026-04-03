import Testing
import Foundation
@testable import Core

@Suite("NotificationBatcher")
struct NotificationBatcherTests {

    private func makeEvent(
        sessionId: String = "session-1",
        type: EventType = .permissionNeeded,
        tier: AttentionTier = .action
    ) -> DevEvent {
        DevEvent(
            id: UUID().uuidString, sessionId: sessionId, type: type,
            title: "Event", detail: "/project", payload: "{}",
            tokenCount: nil, durationSeconds: nil,
            timestamp: Date(), attentionTier: tier
        )
    }

    @Test("Single event produces immediate notification")
    func singleEvent() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        batcher.submit(makeEvent())
        batcher.flush()
        #expect(notifications.count == 1)
        #expect(notifications.first?.isBatched == false)
    }

    @Test("2 events within 2s same session produce 2 separate notifications")
    func twoEventsSameSession() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        batcher.submit(makeEvent())
        batcher.submit(makeEvent())
        batcher.flush()
        #expect(notifications.count == 2)
    }

    @Test("4+ events within 2s same session produce 1 batched notification")
    func batchedSameSession() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        for _ in 0..<4 { batcher.submit(makeEvent()) }
        batcher.flush()
        #expect(notifications.count == 1)
        #expect(notifications.first?.isBatched == true)
        #expect(notifications.first?.eventCount == 4)
    }

    @Test("4 events within 2s different sessions produce 4 notifications")
    func differentSessions() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        for i in 0..<4 { batcher.submit(makeEvent(sessionId: "session-\(i)")) }
        batcher.flush()
        #expect(notifications.count == 4)
    }

    @Test("Global throttle: 6th notification in window becomes summary")
    func globalThrottle() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher(globalMaxPerWindow: 5) { notifications.append($0) }
        for i in 0..<6 { batcher.submit(makeEvent(sessionId: "s-\(i)")) }
        batcher.flush()
        let summaries = notifications.filter(\.isSummary)
        #expect(summaries.count == 1)
    }

    @Test("submitIdle emits notification immediately with correct content")
    func submitIdle() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        batcher.submitIdle(sessionId: "session-1", project: "my-project")
        #expect(notifications.count == 1)
        let n = notifications[0]
        #expect(n.sessionId == "session-1")
        #expect(n.title == "my-project")
        #expect(n.body == "Claude is ready")
        #expect(n.isBatched == false)
        #expect(n.isSummary == false)
        #expect(n.event == nil)
    }

    @Test("submitIdle respects global rate limit")
    func submitIdleGlobalThrottle() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher(globalMaxPerWindow: 3) { notifications.append($0) }
        for i in 0..<4 { batcher.submitIdle(sessionId: "s-\(i)", project: "p") }
        let summaries = notifications.filter(\.isSummary)
        #expect(summaries.count == 1)
    }

    @Test("background events do not emit notifications when filtered at call site")
    func backgroundEventsFiltered() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        let bgEvent = makeEvent(type: .promptSubmitted, tier: .background)
        // Simulate the AppState guard: only submit non-background events
        if bgEvent.attentionTier != .background {
            batcher.submit(bgEvent)
            batcher.flush()
        }
        #expect(notifications.isEmpty)
    }

    @Test("submitIdle with tool=cursor emits 'Cursor is ready' body")
    func submitIdleCursorTool() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        batcher.submitIdle(sessionId: "cursor-1", project: "my-project", tool: "cursor")
        #expect(notifications.count == 1)
        #expect(notifications[0].body == "Cursor is ready")
    }

    @Test("submitIdle with tool=claude-code emits 'Claude is ready' body")
    func submitIdleClaudeCodeTool() {
        var notifications: [NotificationBatcher.Notification] = []
        let batcher = NotificationBatcher { notifications.append($0) }
        batcher.submitIdle(sessionId: "cc-1", project: "my-project", tool: "claude-code")
        #expect(notifications.count == 1)
        #expect(notifications[0].body == "Claude is ready")
    }
}

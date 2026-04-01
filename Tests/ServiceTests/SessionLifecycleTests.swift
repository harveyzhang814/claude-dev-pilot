import Testing
import Foundation
import GRDB
@testable import Core

@Suite("SessionLifecycle")
struct SessionLifecycleTests {

    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try DatabaseManager.migrate(dbQueue)
        return dbQueue
    }

    private func makeEvent(
        sessionId: String = "session-1",
        type: EventType = .taskCompleted,
        tier: AttentionTier = .review,
        cwd: String = "/Users/dev/project"
    ) -> DevEvent {
        DevEvent(
            id: UUID().uuidString, sessionId: sessionId, type: type,
            title: "Test event", detail: cwd, payload: "{}",
            tokenCount: nil, durationSeconds: nil,
            timestamp: Date(), attentionTier: tier
        )
    }

    @Test("First event creates new session as running")
    func firstEventCreatesSession() throws {
        let db = try makeDB()
        let event = makeEvent(type: .taskStarted)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session != nil)
        #expect(session?.status == .running)
        #expect(session?.id == event.sessionId)
    }

    @Test("permissionNeeded event sets status to waiting")
    func permissionNeededSetsWaiting() throws {
        let db = try makeDB()
        let event = makeEvent(type: .permissionNeeded, tier: .action)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .waiting)
    }

    @Test("taskCompleted event closes session")
    func taskCompletedClosesSession() throws {
        let db = try makeDB()
        let event = makeEvent(type: .taskCompleted)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .completed)
        #expect(session?.endedAt != nil)
    }

    @Test("taskError event closes session")
    func taskErrorClosesSession() throws {
        let db = try makeDB()
        let event = makeEvent(type: .taskError, tier: .review)
        try SessionLifecycleService.processEvent(event, in: db)

        let session = try SessionStore.fetch(id: event.sessionId, in: db)
        #expect(session?.status == .error)
        #expect(session?.endedAt != nil)
    }

    @Test("Event for completed session reopens it")
    func eventReopensCompletedSession() throws {
        let db = try makeDB()
        // First: create and complete the session
        let completedEvent = makeEvent(type: .taskCompleted)
        try SessionLifecycleService.processEvent(completedEvent, in: db)

        let closed = try SessionStore.fetch(id: completedEvent.sessionId, in: db)
        #expect(closed?.status == .completed)

        // Then: send a new event for the same session
        let newEvent = makeEvent(sessionId: completedEvent.sessionId, type: .taskStarted)
        try SessionLifecycleService.processEvent(newEvent, in: db)

        let reopened = try SessionStore.fetch(id: completedEvent.sessionId, in: db)
        #expect(reopened?.status == .running)
        #expect(reopened?.endedAt == nil)
    }

    @Test("Subsequent event updates lastEventTitle")
    func subsequentEventUpdatesTitle() throws {
        let db = try makeDB()
        let firstEvent = makeEvent(type: .taskStarted)
        try SessionLifecycleService.processEvent(firstEvent, in: db)

        let secondEvent = DevEvent(
            id: UUID().uuidString,
            sessionId: firstEvent.sessionId,
            type: .taskStarted,
            title: "Updated title",
            detail: "/Users/dev/project",
            payload: "{}",
            tokenCount: nil,
            durationSeconds: nil,
            timestamp: Date(),
            attentionTier: .background
        )
        try SessionLifecycleService.processEvent(secondEvent, in: db)

        let session = try SessionStore.fetch(id: firstEvent.sessionId, in: db)
        #expect(session?.lastEventTitle == "Updated title")
    }
}

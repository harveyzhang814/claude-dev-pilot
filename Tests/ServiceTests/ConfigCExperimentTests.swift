// Tests/ServiceTests/ConfigCExperimentTests.swift
import Testing
import Foundation
import GRDB
@testable import Core

/// Config C experiment: both HTTP hooks AND file watcher fire events for the same session.
/// Observes whether duplicate events cause state corruption or problematic side effects.
@Suite("ConfigCExperiment")
struct ConfigCExperimentTests {

    // Helper: create a coordinator with in-memory DB
    private func makeCoordinator(windowMs: Int = 100) throws -> (HookStreamCoordinator, DatabaseQueue) {
        let db = try DatabaseQueue()
        try DatabaseManager.migrate(db)
        let coordinator = HookStreamCoordinator(
            db: db,
            stopWindowDuration: .milliseconds(windowMs)
        )
        return (coordinator, db)
    }

    // Helper: fetch session status
    private func sessionStatus(_ sessionId: String, db: DatabaseQueue) async throws -> String? {
        try await db.read { db in
            try DevSession.fetchOne(db, key: sessionId)?.status.rawValue
        }
    }

    // Helper: count events for session
    private func eventCount(_ sessionId: String, db: DatabaseQueue) async throws -> Int {
        try await db.read { db in
            try DevEvent.filter(Column("session_id") == sessionId).fetchCount(db)
        }
    }

    // Helper: count undismissed events for session
    private func undismissedEventCount(_ sessionId: String, db: DatabaseQueue) async throws -> Int {
        try await db.read { db in
            try DevEvent
                .filter(Column("session_id") == sessionId)
                .filter(Column("is_dismissed") == false)
                .fetchCount(db)
        }
    }

    // MARK: - Scenario 1: Double UserPromptSubmit (hook then file watcher)

    @Test("Scenario 1: UserPromptSubmit from hook then file watcher — double dismiss?")
    func doubleUserPromptSubmit() async throws {
        let (coordinator, db) = try makeCoordinator()
        let sessionId = "exp-sess-1"

        // Start session via hook
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "SessionStart",
            eventSource: .hook
        ))

        // First user prompt via hook — creates event, dismisses prior
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .hook
        ))
        let statusAfterHook = try await sessionStatus(sessionId, db: db)

        // Add a Stop + idle resolution so there's an agentStopped event to potentially dismiss
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "Stop",
            eventSource: .hook
        ))
        // Wait for stop window to expire → session becomes idle, agentStopped DevEvent inserted
        try await Task.sleep(for: .milliseconds(200))

        let eventsBeforeSecondPrompt = try await eventCount(sessionId, db: db)
        let undismissedBefore = try await undismissedEventCount(sessionId, db: db)

        // Same UserPromptSubmit arrives from file watcher (simulating duplicate)
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .fileWatcher
        ))
        let statusAfterFW = try await sessionStatus(sessionId, db: db)
        let eventsAfterSecondPrompt = try await eventCount(sessionId, db: db)
        let undismissedAfter = try await undismissedEventCount(sessionId, db: db)

        print("--- Scenario 1: Double UserPromptSubmit ---")
        print("Status after hook UserPromptSubmit: \(statusAfterHook ?? "nil")")
        print("Status after fileWatcher UserPromptSubmit: \(statusAfterFW ?? "nil")")
        print("Events before second prompt: \(eventsBeforeSecondPrompt), undismissed: \(undismissedBefore)")
        print("Events after second prompt: \(eventsAfterSecondPrompt), undismissed: \(undismissedAfter)")
        print("Net new DevEvents from FW prompt: \(eventsAfterSecondPrompt - eventsBeforeSecondPrompt)")
        print("Undismissed change: \(undismissedBefore) → \(undismissedAfter)")

        // Both should result in .busy status (idempotent)
        #expect(statusAfterHook == "busy")
        #expect(statusAfterFW == "busy")
    }

    // MARK: - Scenario 2: Double Stop (hook then file watcher)

    @Test("Scenario 2: Stop from hook then file watcher — stop window restart?")
    func doubleStop() async throws {
        let (coordinator, db) = try makeCoordinator()
        let sessionId = "exp-sess-2"

        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "SessionStart",
            eventSource: .hook
        ))
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .hook
        ))

        // Stop from hook → starts 100ms stop window
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "Stop",
            eventSource: .hook
        ))
        // Immediately, Stop from file watcher → should reset/restart stop window
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "Stop",
            eventSource: .fileWatcher
        ))

        // Wait for both windows to expire (original + restarted)
        try await Task.sleep(for: .milliseconds(300))

        let finalStatus = try await sessionStatus(sessionId, db: db)
        let events = try await db.read { db in try DevEvent.filter(Column("session_id") == sessionId).fetchAll(db) }
        let agentStoppedCount = events.filter { $0.type == .agentStopped }.count

        print("--- Scenario 2: Double Stop ---")
        print("Final status after double Stop + window expiry: \(finalStatus ?? "nil")")
        print("agentStopped events inserted: \(agentStoppedCount) (expected 1, >1 would mean duplicate)")
        #expect(finalStatus == "idle")
        // Key question: did double Stop insert duplicate agentStopped events?
        #expect(agentStoppedCount == 1, "Double Stop should produce exactly 1 agentStopped event")
    }

    // MARK: - Scenario 3: File-watcher only (no hooks installed)

    @Test("Scenario 3: File-watcher only — full busy/idle cycle")
    func fileWatcherOnly() async throws {
        let (coordinator, db) = try makeCoordinator()
        let sessionId = "exp-sess-3"

        // File watcher fires these in sequence (as if reading JSONL)
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .fileWatcher
        ))
        let statusBusy = try await sessionStatus(sessionId, db: db)

        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "Stop",
            eventSource: .fileWatcher
        ))
        try await Task.sleep(for: .milliseconds(200))
        let statusIdle = try await sessionStatus(sessionId, db: db)

        // Second turn
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .fileWatcher
        ))
        let statusBusy2 = try await sessionStatus(sessionId, db: db)

        let totalEvents = try await eventCount(sessionId, db: db)

        print("--- Scenario 3: File-watcher only ---")
        print("After UserPromptSubmit (no prior SessionStart): \(statusBusy ?? "nil")")
        print("After Stop + window: \(statusIdle ?? "nil")")
        print("After second UserPromptSubmit: \(statusBusy2 ?? "nil")")
        print("Total DevEvents created: \(totalEvents)")
        print("NOTE: first UserPromptSubmit without SessionStart creates session as idle (known behavior gap)")
        print("      updateSessionStatus falls back to creating session with status=idle, not busy")

        // OBSERVATION: When no SessionStart precedes UserPromptSubmit, the session is created
        // as .idle (fallback in updateSessionStatus), not .busy. This is a known gap for
        // file-watcher-only mode where SessionStart may not be observed.
        #expect(statusBusy == "idle", "Without SessionStart, session falls back to idle creation")
        #expect(statusIdle == "idle")
        #expect(statusBusy2 == "busy")
    }

    // MARK: - Scenario 4: Rapid interleave (hook and FW within milliseconds)

    @Test("Scenario 4: Hook and FW UserPromptSubmit within same async batch — state after both")
    func rapidInterleave() async throws {
        let (coordinator, db) = try makeCoordinator()
        let sessionId = "exp-sess-4"

        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "SessionStart",
            eventSource: .hook
        ))

        // Fire both sources nearly simultaneously using async let
        async let hookFire: Void = coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .hook
        ))
        async let fwFire: Void = coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .fileWatcher
        ))
        _ = await (hookFire, fwFire)

        let finalStatus = try await sessionStatus(sessionId, db: db)
        let totalEvents = try await eventCount(sessionId, db: db)
        // promptSubmitted events (background tier) — one per UserPromptSubmit processed
        let promptEvents = try await db.read { db in
            try DevEvent.filter(Column("session_id") == sessionId)
                        .filter(Column("type") == "promptSubmitted")
                        .fetchCount(db)
        }

        print("--- Scenario 4: Rapid interleave ---")
        print("Final status after concurrent UserPromptSubmit: \(finalStatus ?? "nil")")
        print("Total DevEvents: \(totalEvents)")
        print("promptSubmitted DevEvents: \(promptEvents) (2 = both fired, 1 = deduped by actor serialization)")
        #expect(finalStatus == "busy")
    }

    // MARK: - Scenario 5: Hook fires SessionStart, FW fires UserPromptSubmit before hook does

    @Test("Scenario 5: FW UserPromptSubmit races ahead of hook UserPromptSubmit")
    func fileWatcherAheadOfHook() async throws {
        let (coordinator, db) = try makeCoordinator()
        let sessionId = "exp-sess-5"

        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "SessionStart",
            eventSource: .hook
        ))

        // File watcher fires UserPromptSubmit first (e.g. read from JSONL before HTTP arrives)
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .fileWatcher
        ))
        let statusAfterFW = try await sessionStatus(sessionId, db: db)

        // Then the HTTP hook fires (slightly delayed, real-world latency)
        await coordinator.process(HookPayload(
            sessionId: sessionId, cwd: "/proj",
            hookEventName: "UserPromptSubmit",
            eventSource: .hook
        ))
        let statusAfterHook = try await sessionStatus(sessionId, db: db)

        let promptEvents = try await db.read { db in
            try DevEvent.filter(Column("session_id") == sessionId)
                        .filter(Column("type") == "promptSubmitted")
                        .fetchCount(db)
        }

        print("--- Scenario 5: FW ahead of hook ---")
        print("Status after FW UserPromptSubmit: \(statusAfterFW ?? "nil")")
        print("Status after hook UserPromptSubmit: \(statusAfterHook ?? "nil")")
        print("promptSubmitted events: \(promptEvents) (2 means both registered, no dedup)")

        #expect(statusAfterFW == "busy")
        #expect(statusAfterHook == "busy")
    }
}

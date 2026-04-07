// Tests/ServiceTests/SessionStateReducerTests.swift
import Testing
import Foundation
@testable import Core

@Suite("SessionStateReducer")
struct SessionStateReducerTests {

    private let sid = "session-abc"
    private func reduce(_ state: SessionMachineState,
                        _ event: HookEvent) -> (SessionMachineState, [Action]) {
        SessionStateReducer.reduce(state, event)
    }

    // MARK: - Rule 1: SessionStart → idle

    @Test func sessionStartFromInitialCreatesUpsert() {
        let (next, actions) = reduce(.initial, .sessionStart(
            sessionId: sid, cwd: "/proj", tty: "/dev/ttys001",
            terminalApp: "ghostty", tool: "claude-code", source: "startup"))
        #expect(next.status == .idle)
        #expect(next.stopWindowActive == false)
        #expect(next.dbSessionExists == true)
        #expect(next.cwd == "/proj")
        #expect(next.tool == "claude-code")
        #expect(actions.contains(.upsertSession(
            sessionId: sid, status: .idle, cwd: "/proj",
            tty: "/dev/ttys001", terminalApp: "ghostty",
            tool: "claude-code", source: "startup")))
    }

    @Test func sessionStartResetsCompletedSession() {
        var state = SessionMachineState.initial
        state.status = .completed
        let (next, actions) = reduce(state, .sessionStart(
            sessionId: sid, cwd: "/proj", tty: nil,
            terminalApp: nil, tool: "claude-code", source: "resume"))
        #expect(next.status == .idle)
        #expect(actions.contains(.upsertSession(
            sessionId: sid, status: .idle, cwd: "/proj",
            tty: nil, terminalApp: nil, tool: "claude-code", source: "resume")))
    }

    @Test func sessionStartCancelsStopWindow() {
        var state = SessionMachineState.initial
        state.stopWindowActive = true
        let (next, actions) = reduce(state, .sessionStart(
            sessionId: sid, cwd: "/proj", tty: nil,
            terminalApp: nil, tool: "claude-code", source: nil))
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
    }

    // MARK: - Rule 2: SessionEnd → completed

    @Test func sessionEndSetsCompleted() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .sessionEnd(sessionId: sid))
        #expect(next.status == .completed)
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .completed)))
    }

    @Test func sessionEndCancelsActiveStopWindow() {
        var state = SessionMachineState.initial
        state.stopWindowActive = true
        let (next, actions) = reduce(state, .sessionEnd(sessionId: sid))
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
    }

    // MARK: - Rule 3: UserPromptSubmit → busy

    @Test func userPromptSubmitSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .userPromptSubmit(sessionId: sid))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
        #expect(actions.contains(.dismissPriorEvents(sessionId: sid)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .promptSubmitted,
            title: "Prompt submitted", cwd: nil, attentionTier: .background)))
    }

    @Test func userPromptSubmitFromIdleSetsBusy() {
        let (next, _) = reduce(.initial, .userPromptSubmit(sessionId: sid))
        #expect(next.status == .busy)
    }

    // MARK: - Rule 11: PreToolUse (non-AQU) when idle/waiting → busy

    @Test func preToolUseFromIdleSetsBusy() {
        let (next, actions) = reduce(.initial, .preToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
    }

    @Test func preToolUseFromWaitingSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "Read"))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
    }

    @Test func preToolUseFromBusyIsNoop() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
        #expect(actions.isEmpty)
    }

    // MARK: - Rule 4: PreToolUse/AskUserQuestion → waiting

    @Test func preToolUseAskUserQuestionSetsWaiting() {
        var state = SessionMachineState.initial
        state.status = .busy
        state.cwd = "/proj"
        let (next, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(next.status == .waiting)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .waiting)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: "/proj", attentionTier: .action)))
    }

    @Test func preToolUseAskUserQuestionFromIdleSetsWaiting() {
        let (next, _) = reduce(.initial, .preToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(next.status == .waiting)
    }

    // MARK: - Rule 5: Notification(permissionPrompt) during stop window → cancel + waiting

    @Test func notificationPermissionPromptDuringStopWindowCancelsAndSetsWaiting() {
        var state = SessionMachineState.initial
        state.status = .idle
        state.stopWindowActive = true
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(next.status == .waiting)
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.cancelStopWindow(sessionId: sid)))
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .waiting)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: nil, attentionTier: .action)))
    }

    // MARK: - Rule 6: Notification(permissionPrompt) when not waiting → waiting

    @Test func notificationPermissionPromptFromBusySetsWaiting() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(next.status == .waiting)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .waiting)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: nil, attentionTier: .action)))
    }

    // MARK: - Rule 7: Notification(permissionPrompt) already waiting → no-op (idempotent)

    @Test func notificationPermissionPromptWhenAlreadyWaitingIsNoop() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(next.status == .waiting)
        #expect(actions.isEmpty)
    }

    // MARK: - Rule 8: PostToolUse when waiting → busy

    @Test func postToolUseWhenWaitingSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(next.status == .busy)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .busy)))
    }

    @Test func postToolUseAnyToolWhenWaitingSetsBusy() {
        var state = SessionMachineState.initial
        state.status = .waiting
        let (next, _) = reduce(state, .postToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
    }

    @Test func postToolUseWhenBusyIsNoop() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "Bash"))
        #expect(next.status == .busy)
        #expect(actions.isEmpty)
    }

    // MARK: - Rule 9: Stop → start window

    @Test func stopStartsStopWindow() {
        let (next, actions) = reduce(.initial, .stop(sessionId: sid))
        #expect(next.stopWindowActive == true)
        #expect(next.status == .idle)   // status unchanged from initial
        #expect(actions.contains(.startStopWindow(sessionId: sid)))
    }

    @Test func stopFromBusyStartsWindow() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .stop(sessionId: sid))
        #expect(next.status == .busy)   // status unchanged by Stop alone
        #expect(next.stopWindowActive == true)
        #expect(actions == [.startStopWindow(sessionId: sid)])
    }

    // MARK: - Rule 10: stopWindowExpired → idle + agentStopped

    @Test func stopWindowExpiredSetsIdleAndInsertsReadyEvent() {
        var state = SessionMachineState.initial
        state.status = .busy
        state.stopWindowActive = true
        state.cwd = "/proj"
        state.tool = "claude-code"
        let (next, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(next.status == .idle)
        #expect(next.stopWindowActive == false)
        #expect(actions.contains(.updateSessionStatus(sessionId: sid, status: .idle)))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Claude is ready", cwd: "/proj", attentionTier: .review)))
    }

    @Test func stopWindowExpiredCursorUsesCursorTitle() {
        var state = SessionMachineState.initial
        state.stopWindowActive = true
        state.tool = "cursor"
        let (_, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Cursor is ready", cwd: nil, attentionTier: .review)))
    }

    // MARK: - No-ops (Rules 12–13)

    @Test func notificationIdlePromptIsNoop() {
        var state = SessionMachineState.initial
        state.status = .busy
        let (next, actions) = reduce(state, .notification(sessionId: sid, kind: .idlePrompt))
        #expect(next.status == .busy)
        #expect(actions.isEmpty)
    }

    @Test func notificationOtherIsNoop() {
        let (next, actions) = reduce(.initial, .notification(sessionId: sid, kind: .other))
        #expect(next == .initial)
        #expect(actions.isEmpty)
    }

    // MARK: - Full path integration tests

    @Test func askUserQuestionFullPath() {
        var state = SessionMachineState.initial
        state.cwd = "/proj"
        var actions: [Action]

        // UserPromptSubmit → busy
        (state, actions) = reduce(state, .userPromptSubmit(sessionId: sid))
        #expect(state.status == .busy)

        // PreToolUse/AskUserQuestion → waiting + permissionNeeded event
        (state, actions) = reduce(state, .preToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(state.status == .waiting)
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .permissionNeeded,
            title: "Claude Code needs your attention",
            cwd: "/proj", attentionTier: .action)))

        // Notification(permissionPrompt) → no-op (idempotent, already waiting)
        (state, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(state.status == .waiting)
        #expect(actions.isEmpty)

        // PostToolUse/AskUserQuestion → busy
        (state, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "AskUserQuestion"))
        #expect(state.status == .busy)

        // Stop → window active
        (state, actions) = reduce(state, .stop(sessionId: sid))
        #expect(state.stopWindowActive == true)
        #expect(actions.contains(.startStopWindow(sessionId: sid)))

        // stopWindowExpired → idle + agentStopped
        (state, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(state.status == .idle)
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Claude is ready", cwd: "/proj", attentionTier: .review)))
    }

    @Test func permissionApprovalFullPath() {
        var state = SessionMachineState.initial
        var actions: [Action]

        (state, _) = reduce(state, .userPromptSubmit(sessionId: sid))
        (state, _) = reduce(state, .preToolUse(sessionId: sid, toolName: "Bash"))
        #expect(state.status == .busy)   // PreToolUse/Bash when busy → no-op

        (state, actions) = reduce(state, .notification(sessionId: sid, kind: .permissionPrompt))
        #expect(state.status == .waiting)

        (state, actions) = reduce(state, .postToolUse(sessionId: sid, toolName: "Bash"))
        #expect(state.status == .busy)

        (state, _) = reduce(state, .stop(sessionId: sid))
        (state, actions) = reduce(state, .stopWindowExpired(sessionId: sid))
        #expect(state.status == .idle)
        #expect(actions.contains(.insertDevEvent(
            sessionId: sid, type: .agentStopped,
            title: "Claude is ready", cwd: nil, attentionTier: .review)))
    }
}

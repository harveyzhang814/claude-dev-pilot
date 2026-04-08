// Sources/Core/Services/SessionStateReducer.swift
import Foundation

public enum SessionStateReducer {
    public static func reduce(
        _ state: SessionMachineState,
        _ event: HookEvent
    ) -> (SessionMachineState, [Action]) {
        var s = state
        let sid = event.sessionId

        switch event {

        // Rule 1: SessionStart → idle (reopen if completed/stale)
        case .sessionStart(_, let cwd, let tty, let terminalApp, let tool, let source):
            s.status = .idle
            s.stopWindowActive = false
            s.cwd = cwd
            s.tool = tool
            s.dbSessionExists = true
            var actions: [Action] = [
                .upsertSession(sessionId: sid, status: .idle, cwd: cwd,
                               tty: tty, terminalApp: terminalApp,
                               tool: tool, source: source)
            ]
            if state.stopWindowActive {
                actions.insert(.cancelStopWindow(sessionId: sid), at: 0)
            }
            return (s, actions)

        // Rule 2: SessionEnd → completed
        case .sessionEnd(_):
            s.status = .completed
            s.stopWindowActive = false
            return (s, [
                .cancelStopWindow(sessionId: sid),
                .updateSessionStatus(sessionId: sid, status: .completed)
            ])

        // Rule 3: UserPromptSubmit → busy + dismiss prior events
        case .userPromptSubmit(_):
            s.status = .busy
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .busy),
                .dismissPriorEvents(sessionId: sid),
                .insertDevEvent(sessionId: sid, type: .promptSubmitted,
                                title: "Prompt submitted",
                                cwd: s.cwd, attentionTier: .background)
            ])

        // Rule 4: PreToolUse/AskUserQuestion → waiting (any current state)
        case .preToolUse(_, "AskUserQuestion"):
            s.status = .waiting
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .waiting),
                .insertDevEvent(sessionId: sid, type: .permissionNeeded,
                                title: "Claude Code needs your attention",
                                cwd: s.cwd, attentionTier: .action)
            ])

        // Rule 5: Notification(permissionPrompt) during stop window → no-op.
        // Stop only fires when the agent loop exits, which cannot happen while a
        // permission dialog is genuinely open. A notification arriving during the
        // stop window is a stale/delayed delivery from an already-approved permission.
        // Cancelling the window here and going to waiting leaves the session stuck
        // because no PostToolUse will arrive to clear it.
        case .notification(_, .permissionPrompt) where s.stopWindowActive:
            return (s, [])

        // Rule 6: Notification(permissionPrompt) while busy → waiting.
        // Only transition from .busy: idle/stale/completed sessions receiving a late
        // notification must not be pulled back into waiting.
        case .notification(_, .permissionPrompt) where s.status == .busy:
            s.status = .waiting
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .waiting),
                .insertDevEvent(sessionId: sid, type: .permissionNeeded,
                                title: "Claude Code needs your attention",
                                cwd: s.cwd, attentionTier: .action)
            ])

        // Rule 7: Notification(permissionPrompt) — any other state → no-op.
        // Covers: already waiting (idempotent), idle, completed, stale.
        case .notification(_, .permissionPrompt):
            return (s, [])

        // Rule 8: PostToolUse (any tool) when waiting → busy
        case .postToolUse(_, _) where s.status == .waiting:
            s.status = .busy
            return (s, [.updateSessionStatus(sessionId: sid, status: .busy)])

        // Rule 9: Stop → start 2s coalescing window (status unchanged)
        case .stop(_):
            s.stopWindowActive = true
            return (s, [.startStopWindow(sessionId: sid)])

        // Rule 10: stopWindowExpired → idle + "ready" review event
        case .stopWindowExpired(_):
            s.status = .idle
            s.stopWindowActive = false
            let readyTitle = s.tool == "cursor" ? "Cursor is ready" : "Claude is ready"
            return (s, [
                .updateSessionStatus(sessionId: sid, status: .idle),
                .insertDevEvent(sessionId: sid, type: .agentStopped,
                                title: readyTitle,
                                cwd: s.cwd, attentionTier: .review)
            ])

        // Rule 11: PreToolUse (non-AskUserQuestion) when idle or waiting → busy
        case .preToolUse(_, let toolName)
                where toolName != "AskUserQuestion"
                   && (s.status == .idle || s.status == .waiting):
            s.status = .busy
            return (s, [.updateSessionStatus(sessionId: sid, status: .busy)])

        // Rules 12–13: idlePrompt and everything else → no-op
        default:
            return (s, [])
        }
    }
}

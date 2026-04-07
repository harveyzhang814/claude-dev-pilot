// Tests/ServiceTests/HookEventClassifierTests.swift
import Testing
import Foundation
@testable import Core

@Suite("HookEventClassifier")
struct HookEventClassifierTests {

    private func payload(
        hookEventName: String,
        sessionId: String = "sid-1",
        cwd: String = "/proj",
        notificationType: String? = nil,
        toolName: String? = nil,
        tool: String? = nil,
        tty: String? = nil,
        terminalApp: String? = nil,
        source: String? = nil
    ) -> HookPayload {
        HookPayload(sessionId: sessionId, cwd: cwd, hookEventName: hookEventName,
                    notificationType: notificationType, source: source, tty: tty,
                    terminalApp: terminalApp, tool: tool, toolName: toolName)
    }

    @Test func sessionStart() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "SessionStart", tool: "cursor", tty: "/dev/ttys001",
                    terminalApp: "ghostty", source: "startup"))
        #expect(event == .sessionStart(sessionId: "sid-1", cwd: "/proj",
                                       tty: "/dev/ttys001", terminalApp: "ghostty",
                                       tool: "cursor", source: "startup"))
    }

    @Test func sessionStartDefaultsTool() {
        let event = HookEventClassifier.classify(payload(hookEventName: "SessionStart"))
        guard case .sessionStart(_, _, _, _, let tool, _) = event! else {
            Issue.record("Expected sessionStart"); return
        }
        #expect(tool == "claude-code")
    }

    @Test func sessionEnd() {
        let event = HookEventClassifier.classify(payload(hookEventName: "SessionEnd"))
        #expect(event == .sessionEnd(sessionId: "sid-1"))
    }

    @Test func userPromptSubmit() {
        let event = HookEventClassifier.classify(payload(hookEventName: "UserPromptSubmit"))
        #expect(event == .userPromptSubmit(sessionId: "sid-1"))
    }

    @Test func preToolUse() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "PreToolUse", toolName: "Bash"))
        #expect(event == .preToolUse(sessionId: "sid-1", toolName: "Bash"))
    }

    @Test func preToolUseWithoutToolNameReturnsNil() {
        let event = HookEventClassifier.classify(payload(hookEventName: "PreToolUse"))
        #expect(event == nil)
    }

    @Test func postToolUse() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "PostToolUse", toolName: "AskUserQuestion"))
        #expect(event == .postToolUse(sessionId: "sid-1", toolName: "AskUserQuestion"))
    }

    @Test func notificationPermissionPrompt() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "permission_prompt"))
        #expect(event == .notification(sessionId: "sid-1", kind: .permissionPrompt))
    }

    @Test func notificationElicitationDialog() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "elicitation_dialog"))
        #expect(event == .notification(sessionId: "sid-1", kind: .permissionPrompt))
    }

    @Test func notificationIdlePrompt() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "idle_prompt"))
        #expect(event == .notification(sessionId: "sid-1", kind: .idlePrompt))
    }

    @Test func notificationOther() {
        let event = HookEventClassifier.classify(
            payload(hookEventName: "Notification", notificationType: "unknown_type"))
        #expect(event == .notification(sessionId: "sid-1", kind: .other))
    }

    @Test func stop() {
        let event = HookEventClassifier.classify(payload(hookEventName: "Stop"))
        #expect(event == .stop(sessionId: "sid-1"))
    }

    @Test func unknownHookEventNameReturnsNil() {
        let event = HookEventClassifier.classify(payload(hookEventName: "UnknownHook"))
        #expect(event == nil)
    }
}

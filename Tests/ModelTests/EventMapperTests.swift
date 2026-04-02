import Testing
import Foundation
@testable import Core

@Suite("EventMapper")
struct EventMapperTests {

    // MARK: - Notification hook routing

    @Test("permission_prompt → permissionNeeded + action")
    func permissionPrompt() throws {
        let payload = makePayload(hookEventName: "Notification", notificationType: "permission_prompt")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("elicitation_dialog → permissionNeeded + action")
    func elicitationDialog() throws {
        let payload = makePayload(hookEventName: "Notification", notificationType: "elicitation_dialog")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("idle_prompt → agentStopped + background")
    func idlePrompt() throws {
        let payload = makePayload(hookEventName: "Notification", notificationType: "idle_prompt")
        let event = EventMapper.map(payload)
        #expect(event.type == .agentStopped)
        #expect(event.attentionTier == .background)
    }

    @Test("auth_success → authSuccess + background")
    func authSuccess() throws {
        let payload = makePayload(hookEventName: "Notification", notificationType: "auth_success")
        let event = EventMapper.map(payload)
        #expect(event.type == .authSuccess)
        #expect(event.attentionTier == .background)
    }

    @Test("Notification with unknown type → agentStopped + background")
    func unknownNotificationType() throws {
        let payload = makePayload(hookEventName: "Notification", notificationType: nil)
        let event = EventMapper.map(payload)
        #expect(event.type == .agentStopped)
        #expect(event.attentionTier == .background)
    }

    // MARK: - Non-Notification hook routing

    @Test("UserPromptSubmit → promptSubmitted + background")
    func userPromptSubmit() throws {
        let payload = makePayload(hookEventName: "UserPromptSubmit")
        let event = EventMapper.map(payload)
        #expect(event.type == .promptSubmitted)
        #expect(event.attentionTier == .background)
    }

    @Test("Stop → agentStopped + background")
    func stop() throws {
        let payload = makePayload(hookEventName: "Stop")
        let event = EventMapper.map(payload)
        #expect(event.type == .agentStopped)
        #expect(event.attentionTier == .background)
    }

    @Test("Unknown hookEventName → agentStopped + background")
    func unknownHookEventName() throws {
        let payload = makePayload(hookEventName: "SomeFutureHook")
        let event = EventMapper.map(payload)
        #expect(event.type == .agentStopped)
        #expect(event.attentionTier == .background)
    }

    // MARK: - Field mapping

    @Test("Session ID carried through from payload")
    func sessionIdPassthrough() throws {
        let payload = makePayload(hookEventName: "Notification", notificationType: "idle_prompt",
                                  sessionId: "test-session-42")
        let event = EventMapper.map(payload)
        #expect(event.sessionId == "test-session-42")
    }

    @Test("Raw payload stored as JSON string")
    func rawPayloadStored() throws {
        let payload = makePayload(hookEventName: "Notification", notificationType: "idle_prompt")
        let event = EventMapper.map(payload)
        #expect(event.payload.contains("idle_prompt"))
    }

    // MARK: - Helpers

    private func makePayload(
        hookEventName: String,
        notificationType: String? = nil,
        message: String = "test",
        cwd: String = "/Users/dev/project",
        sessionId: String = "test-session"
    ) -> HookPayload {
        HookPayload(
            sessionId: sessionId,
            cwd: cwd,
            hookEventName: hookEventName,
            message: message,
            transcriptPath: nil,
            title: nil,
            notificationType: notificationType,
            permissionMode: nil
        )
    }
}

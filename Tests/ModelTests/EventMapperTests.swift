import Testing
import Foundation
@testable import AgentDevPilot

@Suite("EventMapper")
struct EventMapperTests {

    // MARK: - notification_type → EventType

    @Test("permission_prompt → permissionNeeded")
    func permissionPrompt() throws {
        let payload = makePayload(notificationType: "permission_prompt", message: "Tool use requires approval")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("elicitation_dialog → permissionNeeded")
    func elicitationDialog() throws {
        let payload = makePayload(notificationType: "elicitation_dialog", message: "MCP server needs input")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("idle_prompt → taskCompleted")
    func idlePrompt() throws {
        let payload = makePayload(notificationType: "idle_prompt", message: "Claude is ready for your next request")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskCompleted)
        #expect(event.attentionTier == .review)
    }

    @Test("auth_success → taskStarted (background)")
    func authSuccess() throws {
        let payload = makePayload(notificationType: "auth_success", message: "Successfully authenticated")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskStarted)
        #expect(event.attentionTier == .background)
    }

    // MARK: - Text matching fallback

    @Test("Message with 'error' and no notification_type → taskError")
    func errorFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Build failed with error")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskError)
        #expect(event.attentionTier == .review)
    }

    @Test("Message with 'permission' and no notification_type → permissionNeeded")
    func permissionFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Permission required to write file")
        let event = EventMapper.map(payload)
        #expect(event.type == .permissionNeeded)
        #expect(event.attentionTier == .action)
    }

    @Test("Message with 'completed' and no notification_type → taskCompleted")
    func completedFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Task completed successfully")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskCompleted)
        #expect(event.attentionTier == .review)
    }

    @Test("No pattern match → taskCompleted (safe default)")
    func noMatchFallback() throws {
        let payload = makePayload(notificationType: nil, message: "Something happened")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskCompleted)
        #expect(event.attentionTier == .review)
    }

    @Test("Multiple keywords: 'completed with error' → error wins (higher priority)")
    func multipleKeywords() throws {
        let payload = makePayload(notificationType: nil, message: "Task completed with error")
        let event = EventMapper.map(payload)
        #expect(event.type == .taskError)
    }

    // MARK: - Field mapping

    @Test("Session ID carried through from payload")
    func sessionIdPassthrough() throws {
        let payload = makePayload(notificationType: "idle_prompt", message: "Done", sessionId: "test-session-42")
        let event = EventMapper.map(payload)
        #expect(event.sessionId == "test-session-42")
    }

    @Test("Raw payload stored as JSON string")
    func rawPayloadStored() throws {
        let payload = makePayload(notificationType: "idle_prompt", message: "Done")
        let event = EventMapper.map(payload)
        #expect(event.payload.contains("idle_prompt"))
    }

    // MARK: - Helpers

    private func makePayload(
        notificationType: String? = nil,
        message: String = "test",
        cwd: String = "/Users/dev/project",
        sessionId: String = "test-session"
    ) -> HookPayload {
        HookPayload(
            sessionId: sessionId,
            cwd: cwd,
            hookEventName: "Notification",
            message: message,
            transcriptPath: nil,
            title: nil,
            notificationType: notificationType,
            permissionMode: nil
        )
    }
}

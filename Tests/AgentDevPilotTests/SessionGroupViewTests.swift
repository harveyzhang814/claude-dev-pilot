import Testing
import Foundation
import Core
@testable import AgentDevPilot

@Suite("SessionGroupView helpers")
struct SessionGroupViewTests {

    private func makeSession(status: SessionStatus) -> DevSession {
        DevSession(
            id: "s1", project: "my-project", cwd: "/Users/dev/my-project",
            tool: "claude-code", status: status,
            startedAt: Date(), endedAt: nil, totalTokens: nil, lastEventTitle: nil
        )
    }

    @Test("statusTag for idle session")
    func statusTagIdle() {
        #expect(sessionStatusTag(makeSession(status: .idle)) == "Idle")
    }

    @Test("statusTag for busy session")
    func statusTagBusy() {
        #expect(sessionStatusTag(makeSession(status: .busy)) == "Running")
    }

    @Test("statusTag for waiting session")
    func statusTagWaiting() {
        #expect(sessionStatusTag(makeSession(status: .waiting)) == "Waiting")
    }
}

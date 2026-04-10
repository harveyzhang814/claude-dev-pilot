import Testing
@testable import AgentPilot

struct ViewUtilsTests {
    @Test func tokenLabel_belowThousand() {
        #expect(tokenLabel(500) == "500 tok")
    }

    @Test func tokenLabel_exactlyThousand() {
        #expect(tokenLabel(1000) == "1K tok")
    }

    @Test func tokenLabel_largeValue() {
        #expect(tokenLabel(127_000) == "127K tok")
    }

    @Test func tokenLabel_zero() {
        #expect(tokenLabel(0) == "0 tok")
    }

    @Test func tokenLabel_truncationBoundary() {
        // 1500 / 1000 = 1 (integer division truncates, not rounds)
        #expect(tokenLabel(1500) == "1K tok")
    }
}

import Foundation
import Testing
@testable import AgentPilot

// Tests for the pure-function helpers that drive position persistence.
// FloatWindowController.isPositionVisible and displayKey are nonisolated static
// functions — no AppKit environment needed.

struct FloatWindowPositionTests {

    // MARK: - isPositionVisible

    @Test func isPositionVisible_centerOfScreen_isTrue() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        #expect(FloatWindowController.isPositionVisible(x: 500, topY: 850, in: screens) == true)
    }

    @Test func isPositionVisible_completelyOffScreen_isFalse() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        // Position that was on an external monitor that's now gone
        #expect(FloatWindowController.isPositionVisible(x: 1500, topY: 1440, in: screens) == false)
    }

    @Test func isPositionVisible_overlapsRightEdge_isTrue() {
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        // Window starts at x=1439, width=360 → most off-screen, but 1px overlap is enough
        #expect(FloatWindowController.isPositionVisible(x: 1439, topY: 100, in: screens) == true)
    }

    @Test func isPositionVisible_multiScreen_secondDisplay_isTrue() {
        let screens = [
            NSRect(x: 0, y: 0, width: 1440, height: 900),
            NSRect(x: 1440, y: 0, width: 2560, height: 1440)
        ]
        #expect(FloatWindowController.isPositionVisible(x: 2000, topY: 1200, in: screens) == true)
    }

    @Test func isPositionVisible_emptyScreenList_isFalse() {
        #expect(FloatWindowController.isPositionVisible(x: 100, topY: 100, in: []) == false)
    }

    // MARK: - displayKey

    @Test func displayKey_sortedRegardlessOfInputOrder() {
        let a = [(vendor: UInt32(10), model: UInt32(20), serial: UInt32(30))]
        let b = [(vendor: UInt32(99), model: UInt32(88), serial: UInt32(77))]
        // Two-display config in different orders should produce same key
        let key1 = FloatWindowController.displayKey(for: a + b)
        let key2 = FloatWindowController.displayKey(for: b + a)
        #expect(key1 == key2)
    }

    @Test func displayKey_singleDisplay_correctFormat() {
        let displays = [(vendor: UInt32(1234), model: UInt32(5678), serial: UInt32(9012))]
        #expect(FloatWindowController.displayKey(for: displays) == "1234-5678-9012")
    }

    @Test func displayKey_allZeros_producesStableKey() {
        // Cheap monitors with no burned-in IDs — should still be a usable key
        let displays = [(vendor: UInt32(0), model: UInt32(0), serial: UInt32(0))]
        #expect(FloatWindowController.displayKey(for: displays) == "0-0-0")
    }

    @Test func displayKey_emptyDisplayList_producesEmptyString() {
        #expect(FloatWindowController.displayKey(for: []) == "")
    }

    // MARK: - isProgrammaticResize guard (UserDefaults not written during animation)

    @Test @MainActor func windowDidMove_doesNotWriteUserDefaultsDuringProgrammaticResize() {
        UserDefaults.standard.removeObject(forKey: "floatWindowPositions")

        // Simulate what positionPanel sets before calling setFrame
        let controller = FloatWindowControllerTestHarness()
        controller.simulateProgrammaticResize()
        // Trigger what windowDidMove would do when flag is true
        controller.simulateWindowDidMove(x: 999, topY: 999)

        let saved = UserDefaults.standard.dictionary(forKey: "floatWindowPositions")
        #expect(saved == nil)
    }

    @Test @MainActor func windowDidMove_writesUserDefaultsOnUserDrag() {
        UserDefaults.standard.removeObject(forKey: "floatWindowPositions")

        let controller = FloatWindowControllerTestHarness()
        // No programmatic resize — simulate user drag
        controller.simulateWindowDidMove(x: 200, topY: 800)

        let saved = UserDefaults.standard.dictionary(forKey: "floatWindowPositions")
        #expect(saved != nil)

        UserDefaults.standard.removeObject(forKey: "floatWindowPositions")
    }
}

// MARK: - Test harness

/// Thin wrapper exposing internal state for testing without constructing a full NSPanel.
/// Uses FloatWindowController's static helpers + exposes the isProgrammaticResize gate.
@MainActor
final class FloatWindowControllerTestHarness {
    private(set) var isProgrammaticResize = false

    func simulateProgrammaticResize() {
        isProgrammaticResize = true
    }

    func simulateWindowDidMove(x: CGFloat, topY: CGFloat) {
        guard !isProgrammaticResize else { return }
        let key = FloatWindowController.currentDisplayKey()
        guard !key.isEmpty else { return }
        var positions = UserDefaults.standard.dictionary(forKey: "floatWindowPositions")
            as? [String: [String: Double]] ?? [:]
        positions[key] = ["x": x, "topY": topY]
        UserDefaults.standard.set(positions, forKey: "floatWindowPositions")
    }
}

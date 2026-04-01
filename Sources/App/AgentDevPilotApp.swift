import SwiftUI

@main
struct AgentDevPilotApp: App {
    var body: some Scene {
        MenuBarExtra("Agent Dev Pilot", systemImage: "bell") {
            Text("Agent Dev Pilot")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

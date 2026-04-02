import SwiftUI
import Core

@main
struct AgentDevPilotApp: App {
    @State private var appState: AppState = AppState()

    var body: some Scene {
        // MenuBar Extra (popover style)
        MenuBarExtra {
            Group {
                if appState.showOnboarding {
                    OnboardingView {
                        appState.completeOnboarding()
                    }
                } else {
                    MenubarPopover(
                        viewModel: appState.popoverViewModel,
                        onFocusSession: { session in
                            let result = TerminalFocusService.focus(session: session)
                            if result == .notFound {
                                openTerminal(at: session.cwd ?? "")
                            }
                        }
                    )
                }
            }
            .task {
                await appState.start()
            }
        } label: {
            if appState.popoverViewModel.actionCount > 0 {
                Image(systemName: "bell.badge.fill")
            } else {
                Image(systemName: "bell.fill")
            }
        }
        .menuBarExtraStyle(.window)

        // Session Panel window
        Window("Sessions", id: "session-panel") {
            SessionPanelView(viewModel: appState.sessionPanelViewModel)
        }
        .defaultSize(width: 400, height: 500)

        // Settings scene
        Settings {
            SettingsView()
        }
    }
}

// MARK: - Terminal helper

private func openTerminal(at path: String) {
    let url: URL
    if path.isEmpty {
        url = URL(fileURLWithPath: NSHomeDirectory())
    } else {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            url = URL(fileURLWithPath: path)
        } else {
            url = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Terminal", url.path]
    try? process.run()
}

import SwiftUI
import Core

@main
struct AgentPilotApp: App {
    @State private var appState: AppState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Group {
                if appState.showOnboarding {
                    OnboardingView {
                        appState.completeOnboarding()
                    }
                } else if appState.floatWindowMode {
                    FloatWindowMenubarTap(appState: appState)
                } else {
                    MenubarPopover(
                        viewModel: appState.popoverViewModel,
                        onFocusSession: { session in
                            focusSession(session)
                        }
                    )
                }
            }
        } label: {
            Group {
                if appState.popoverViewModel.actionCount > 0 {
                    Image(systemName: "bell.badge.fill")
                } else {
                    Image(systemName: "bell.fill")
                }
            }
            // Start the HTTP server and DB on app launch — the label is always
            // visible in the menu bar, so this task fires immediately without
            // requiring the user to click the icon first.
            .task {
                // Register focus handler before start() so FloatWindowController
                // receives it when floatWindowMode is restored.
                appState.focusSessionHandler = { session in focusSession(session) }
                await appState.start()
            }
        }
        .menuBarExtraStyle(.window)

        Window("Sessions", id: "session-panel") {
            SessionPanelView(
                viewModel: appState.sessionPanelViewModel,
                onFocusSession: { session in
                    focusSession(session)
                }
            )
        }
        .defaultSize(width: 400, height: 500)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

// MARK: - Float Window menubar tap

/// In Float Window mode, tapping the menubar icon reveals the float window.
/// If hidden, shows it in compact or hover state (depending on hoverLock).
/// If already visible, triggers a border pulse animation to hint the user to its location.
/// This view closes the MenuBarExtra popup immediately after triggering the reveal.
private struct FloatWindowMenubarTap: View {
    let appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                appState.revealFloatWindow()
                // Close the MenuBarExtra popup that just opened
                NSApplication.shared.keyWindow?.orderOut(nil)
            }
    }
}

// MARK: - Terminal focus

@MainActor
private func focusSession(_ session: DevSession) {
    let result = TerminalFocusService.focus(session: session)
    guard result == .notFound else { return }

    let alert = NSAlert()
    alert.messageText = "Terminal window not found"
    alert.informativeText = "The terminal running \"\(session.project)\" may have been closed. Open a new window instead?"
    alert.addButton(withTitle: "Open New Window")
    alert.addButton(withTitle: "Cancel")

    if alert.runModal() == .alertFirstButtonReturn {
        openTerminal(at: session.cwd ?? "", terminalApp: session.terminalApp)
    }
}

// MARK: - Terminal helper

/// Opens a new terminal window at `path`, using the correct terminal app if known.
private func openTerminal(at path: String, terminalApp: String? = nil) {
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
    let appName: String
    switch terminalApp {
    case "ghostty": appName = "Ghostty"
    default: appName = "Terminal"
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", appName, url.path]
    try? process.run()
}

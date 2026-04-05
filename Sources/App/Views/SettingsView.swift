import SwiftUI
import Core

struct SettingsView: View {
    let appState: AppState

    @AppStorage("serverPort") private var serverPort: Int = 9876
    @AppStorage("soundEnabled") private var soundEnabled: Bool = true
    @AppStorage("retentionDays") private var retentionDays: Int = 30
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false
    @AppStorage("floatWindowMode") private var floatWindowMode: Bool = false

    @State private var showRecentPayloads: Bool = false
    @State private var recentPayloads: [String] = []
    @State private var promptCopied: Bool = false
    @State private var cursorPromptCopied: Bool = false

    var body: some View {
        Form {
            Section("Display") {
                Picker("Mode", selection: $floatWindowMode) {
                    Text("Menubar Popover").tag(false)
                    Text("Float Window").tag(true)
                }
                .pickerStyle(.inline)
                .onChange(of: floatWindowMode) { _, newValue in
                    appState.setFloatWindowMode(newValue)
                }
            }

            // Server section
            Section("Server") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: $serverPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }

            // Notifications section
            Section("Notifications") {
                Toggle("Play sound for action events", isOn: $soundEnabled)
            }

            // Data section
            Section("Data") {
                HStack {
                    Text("Retention (days)")
                    Spacer()
                    TextField("Days", value: $retentionDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                }
            }

            // General section
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Session panel always on top", isOn: $alwaysOnTop)
            }

            // Setup section
            Section("Claude Code Hooks") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste this into any Claude Code session to register the Notification, SessionStart, and SessionEnd hooks:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView {
                        Text(HookInstaller.claudeCodePrompt())
                            .font(.system(.caption2, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(HookInstaller.claudeCodePrompt(), forType: .string)
                        promptCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            promptCopied = false
                        }
                    } label: {
                        Label(promptCopied ? "Copied!" : "Copy Prompt", systemImage: promptCopied ? "checkmark" : "doc.on.doc")
                    }
                }
            }

            // Cursor hooks section
            Section("Cursor Hooks") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste this into Cursor Agent to register the sessionStart, sessionEnd, and stop hooks:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView {
                        Text(HookInstaller.cursorAgentPrompt())
                            .font(.system(.caption2, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(HookInstaller.cursorAgentPrompt(), forType: .string)
                        cursorPromptCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            cursorPromptCopied = false
                        }
                    } label: {
                        Label(cursorPromptCopied ? "Copied!" : "Copy Prompt", systemImage: cursorPromptCopied ? "checkmark" : "doc.on.doc")
                    }
                }
            }

            // Debug section
            Section("Debug") {
                Button("Show Recent Payloads") {
                    showRecentPayloads = true
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .sheet(isPresented: $showRecentPayloads) {
            RecentPayloadsSheet(payloads: recentPayloads, isPresented: $showRecentPayloads)
        }
    }
}

private struct RecentPayloadsSheet: View {
    let payloads: [String]
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent Payloads")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.return)
            }
            .padding()

            Divider()

            if payloads.isEmpty {
                Text("No recent payloads")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(payloads.indices, id: \.self) { index in
                            Text(payloads[index])
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(4)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 500, height: 400)
    }
}

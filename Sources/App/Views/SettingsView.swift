import SwiftUI
import Core

struct SettingsView: View {
    @AppStorage("serverPort") private var serverPort: Int = 9876
    @AppStorage("soundEnabled") private var soundEnabled: Bool = true
    @AppStorage("retentionDays") private var retentionDays: Int = 30
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false

    @State private var showRecentPayloads: Bool = false
    @State private var recentPayloads: [String] = []

    var body: some View {
        Form {
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

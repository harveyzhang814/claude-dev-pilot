import SwiftUI
import Core

struct SessionPanelView: View {
    let viewModel: SessionPanelViewModel
    @AppStorage("alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var staleExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Sessions")
                    .font(.headline)

                if !viewModel.activeSessions.isEmpty {
                    Text("\(viewModel.activeSessions.count) active")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .clipShape(Capsule())
                }

                Spacer()

                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: alwaysOnTop) { _, newValue in
                        setWindowLevel(alwaysOnTop: newValue)
                    }

                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Open Settings")
                .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if viewModel.activeSessions.isEmpty && viewModel.completedSessions.isEmpty && viewModel.staleSessions.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No active sessions")
                        .foregroundColor(.secondary)
                    Text("Start a Claude Code session in any project to see it here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    // Active section
                    if !viewModel.activeSessions.isEmpty {
                        Section("Active") {
                            ForEach(viewModel.activeSessions) { session in
                                SessionRowView(session: session)
                            }
                        }
                    }

                    // Completed section
                    if !viewModel.completedSessions.isEmpty {
                        Section("Completed") {
                            ForEach(viewModel.completedSessions) { session in
                                SessionRowView(session: session)
                            }
                        }
                    }

                    // Inactive/Stale section (collapsed by default)
                    if !viewModel.staleSessions.isEmpty {
                        Section(isExpanded: $staleExpanded) {
                            if staleExpanded {
                                ForEach(viewModel.staleSessions) { session in
                                    SessionRowView(session: session)
                                }
                            }
                        } header: {
                            Button {
                                staleExpanded.toggle()
                            } label: {
                                HStack {
                                    Text("Inactive (\(viewModel.staleSessions.count))")
                                    Spacer()
                                    Image(systemName: staleExpanded ? "chevron.up" : "chevron.down")
                                        .imageScale(.small)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    private func setWindowLevel(alwaysOnTop: Bool) {
        NSApp.windows.forEach { window in
            if window.title == "Sessions" || window.identifier?.rawValue == "session-panel" {
                window.level = alwaysOnTop ? .floating : .normal
            }
        }
    }
}

import SwiftUI
import Core

struct MenubarPopover: View {
    @Environment(\.openWindow) private var openWindow
    let viewModel: PopoverViewModel
    var onOpenTerminal: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.activeSessionCount > 0 {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(viewModel.activeSessionCount) active session\(viewModel.activeSessionCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            }

            // Needs Attention section
            SectionHeader(title: "Needs Attention", count: viewModel.actionEvents.isEmpty ? nil : viewModel.actionEvents.count)

            if viewModel.actionEvents.isEmpty {
                Text("All clear. No sessions need you right now.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.actionEvents) { event in
                    EventCardView(
                        event: event,
                        sessionLabel: viewModel.activeSessionCount > 1
                            ? viewModel.sessionStartedAt(for: event.sessionId).map { sessionAgeLabel($0) }
                            : nil,
                        onOpenTerminal: onOpenTerminal
                    ) {
                        viewModel.dismiss(eventId: event.id)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Recent Activity section
            SectionHeader(title: "Recent Activity", count: nil)

            if viewModel.recentEvents.isEmpty {
                Text("No events yet. Start a Claude Code session to see activity here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(viewModel.recentEvents.prefix(10)) { event in
                    EventCardView(
                        event: event,
                        sessionLabel: viewModel.activeSessionCount > 1
                            ? viewModel.sessionStartedAt(for: event.sessionId).map { sessionAgeLabel($0) }
                            : nil,
                        onOpenTerminal: onOpenTerminal
                    ) {
                        viewModel.dismiss(eventId: event.id)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Open Session Panel") {
                    openWindow(id: "session-panel")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private func sessionAgeLabel(_ date: Date) -> String {
    let s = Int(-date.timeIntervalSinceNow)
    if s < 60 { return "started just now" }
    if s < 3600 { return "started \(s / 60)m ago" }
    return "started \(s / 3600)h ago"
}

private struct SectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            if let count {
                Text("\(count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

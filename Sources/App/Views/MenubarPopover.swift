import SwiftUI
import Core

struct MenubarPopover: View {
    @Environment(\.openWindow) private var openWindow
    let viewModel: PopoverViewModel
    var onOpenTerminal: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    EventCardView(event: event, onOpenTerminal: onOpenTerminal) {
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
                    EventCardView(event: event, onOpenTerminal: onOpenTerminal) {
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

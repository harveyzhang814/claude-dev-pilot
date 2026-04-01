import SwiftUI
import Core

struct MenubarPopover: View {
    @Environment(\.openWindow) private var openWindow
    let viewModel: PopoverViewModel
    var onOpenTerminal: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Needs Attention section
            if !viewModel.actionEvents.isEmpty {
                SectionHeader(title: "Needs Attention", count: viewModel.actionEvents.count)

                ForEach(viewModel.actionEvents) { event in
                    EventCardView(event: event, onOpenTerminal: onOpenTerminal)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }

                Divider()
                    .padding(.vertical, 4)
            }

            // Recent Activity section
            if !viewModel.recentEvents.isEmpty {
                SectionHeader(title: "Recent Activity", count: nil)

                ForEach(viewModel.recentEvents.prefix(10)) { event in
                    EventCardView(event: event, onOpenTerminal: onOpenTerminal)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            }

            // Empty state
            if viewModel.actionEvents.isEmpty && viewModel.recentEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No recent activity")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
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

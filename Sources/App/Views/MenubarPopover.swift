import SwiftUI
import Core

struct MenubarPopover: View {
    @Environment(\.openWindow) private var openWindow
    let viewModel: PopoverViewModel
    var onOpenTerminal: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.activeSessions.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                        .opacity(0.25)
                        .accessibilityHidden(true)
                    Text("No active sessions")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Text("Start Claude Code in any project\nto see it here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(viewModel.activeSessions.enumerated()), id: \.element.id) { index, session in
                            if index > 0 {
                                Divider()
                                    .padding(.vertical, 2)
                            }
                            SessionGroupView(
                                session: session,
                                events: viewModel.eventsBySession[session.id] ?? [],
                                onOpenTerminal: onOpenTerminal
                            ) { eventId in
                                viewModel.dismiss(eventId: eventId)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .clipped()
            }

            Divider()

            // Footer
            HStack {
                Button("Session Panel") {
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

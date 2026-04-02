import SwiftUI
import Core

struct MenubarPopover: View {
    @Environment(\.openWindow) private var openWindow
    let viewModel: PopoverViewModel
    var onFocusSession: ((DevSession) -> Void)?

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
                                displayName: viewModel.displayNames[session.id] ?? session.displayName,
                                events: viewModel.eventsBySession[session.id] ?? [],
                                onFocusSession: onFocusSession
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
                Button {
                    openWindow(id: "session-panel")
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Session Panel")

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Quit")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

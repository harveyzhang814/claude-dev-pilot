import SwiftUI
import Core

struct FloatWindowHoverView: View {
    let sessions: [DevSession]
    let eventsBySession: [String: [DevEvent]]
    let onFocusSession: (DevSession) -> Void
    let onExpand: () -> Void

    private var sortedSessions: [DevSession] {
        let nonStale = sessions.filter { $0.status != .stale }
        let stale = sessions.filter { $0.status == .stale }
        return nonStale + stale
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sortedSessions) { session in
                HoverSessionRowView(
                    session: session,
                    events: eventsBySession[session.id] ?? [],
                    onFocusSession: onFocusSession
                )
            }

            Divider()
                .padding(.top, 2)

            // Toolbar
            HStack(spacing: 0) {
                Button {
                    // No action yet
                } label: {
                    Image(systemName: "gear")
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.clear)
                .cornerRadius(3)

                Spacer()

                Button {
                    onExpand()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.clear)
                .cornerRadius(3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Session Row

private struct HoverSessionRowView: View {
    let session: DevSession
    let events: [DevEvent]
    let onFocusSession: (DevSession) -> Void

    @State private var isHovered = false
    @State private var pulseOpacity: Double = 1.0

    private var rowBackground: Color {
        switch session.status {
        case .waiting:
            return Color(red: 1, green: 0.271, blue: 0.227).opacity(0.09)
        case .idle:
            return Color(red: 1, green: 0.624, blue: 0.039).opacity(0.07)
        case .busy, .stale, .completed:
            return .clear
        }
    }

    private var lastActivityDate: Date {
        events.map(\.timestamp).max() ?? session.startedAt
    }

    var body: some View {
        Button {
            onFocusSession(session)
        } label: {
            HStack(spacing: 8) {
                // Status dot
                ZStack {
                    Circle()
                        .fill(sessionStatusColor(session))
                        .frame(width: 8, height: 8)

                    if session.status == .waiting {
                        Circle()
                            .fill(sessionStatusColor(session))
                            .frame(width: 8, height: 8)
                            .opacity(pulseOpacity)
                    }
                }
                .frame(width: 8, height: 8)

                // Session name + optional tool badge
                HStack(spacing: 4) {
                    Text(session.project)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let badge = sessionToolBadge(session) {
                        Text(badge)
                            .font(.system(size: 10))
                            .foregroundColor(Color(NSColor.secondaryLabelColor))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Status text
                Text(sessionStatusTag(session))
                    .font(.system(size: 11))
                    .foregroundColor(sessionStatusColor(session))
                    .lineLimit(1)

                // Last activity time
                Text(relativeTimeString(from: lastActivityDate))
                    .font(.system(size: 10))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(
                ZStack {
                    rowBackground
                    if isHovered { Color.white.opacity(0.05) }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            if session.status == .waiting {
                withAnimation(
                    .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                ) {
                    pulseOpacity = 0.3
                }
            }
        }
    }
}

// MARK: - Helpers

private func relativeTimeString(from date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h"
}

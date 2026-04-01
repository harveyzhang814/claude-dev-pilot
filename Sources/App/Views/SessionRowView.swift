import SwiftUI
import Core

struct SessionRowView: View {
    let session: DevSession

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator — color AND shape, never color alone
            statusIndicator
                .frame(width: 14, height: 14)
                .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.project)
                    .font(.callout)
                    .bold()
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(session.tool)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(elapsedTime)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let tokens = session.totalTokens {
                Text(tokenLabel(tokens))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .opacity(session.status == .stale ? 0.5 : 1.0)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.status {
        case .running:
            Circle()
                .fill(Color.green)
        case .waiting:
            Image(systemName: "triangle.fill")
                .foregroundColor(.yellow)
                .imageScale(.small)
        case .completed:
            Image(systemName: "checkmark")
                .foregroundColor(.blue)
                .imageScale(.small)
        case .error:
            Image(systemName: "xmark")
                .foregroundColor(.red)
                .imageScale(.small)
        case .stale:
            Rectangle()
                .fill(Color.gray)
                .frame(width: 10, height: 3)
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .running: return "Running"
        case .waiting: return "Waiting for permission"
        case .completed: return "Completed"
        case .error: return "Error"
        case .stale: return "Stale"
        }
    }

    private var elapsedTime: String {
        let end = session.endedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(session.startedAt))
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
    }

    private var rowAccessibilityLabel: String {
        let tokens = session.totalTokens.map { ", \($0) tokens" } ?? ""
        return "\(session.project), \(session.tool), \(statusLabel), \(elapsedTime)\(tokens)"
    }
}

// Internal so tests can reach it without importing a separate module.
func tokenLabel(_ count: Int) -> String {
    if count >= 1000 {
        return "\(count / 1000)K tok"
    }
    return "\(count) tok"
}

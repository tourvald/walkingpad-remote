import SwiftUI

struct DebugSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                content()
            }
        }
    }
}

struct DebugMetricTile: View {
    let title: String
    let value: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
    }
}

struct DebugActionTileLabel: View {
    let title: String
    let subtitle: String
    let tint: Color
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(enabled ? .primary : .secondary)
                .multilineTextAlignment(.leading)

            Text(subtitle)
                .font(.caption2)
                .foregroundColor(enabled ? .secondary : .secondary.opacity(0.8))
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(enabled ? tint.opacity(0.14) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(enabled ? tint.opacity(0.28) : Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .opacity(enabled ? 1.0 : 0.72)
    }
}

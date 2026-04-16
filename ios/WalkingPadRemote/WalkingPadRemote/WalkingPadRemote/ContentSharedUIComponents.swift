import SwiftUI

struct ActionTileButton: View {
    let title: String
    let subtitle: String
    let enabled: Bool
    let tint: Color
    var minWidth: CGFloat = 106
    var fullWidth: Bool = false
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(enabled ? .white.opacity(0.92) : .secondary)
            }
            .foregroundColor(enabled ? .white : .secondary)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .frame(minWidth: fullWidth ? nil : minWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(enabled ? 0.95 : 0.12),
                                tint.opacity(enabled ? 0.75 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        enabled ? Color.white.opacity(0.9) : tint.opacity(0.35),
                        lineWidth: enabled ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: tint.opacity(enabled ? 0.3 : 0), radius: enabled ? 8 : 0, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.85)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}

struct ExtendTimeButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        ActionTileButton(
            title: "+5 мин",
            subtitle: "Продлить",
            enabled: enabled,
            tint: .accentColor,
            accessibilityLabel: "Продлить тренировку на 5 минут",
            accessibilityHint: "Добавляет 5 минут к текущей тренировке",
            action: action
        )
    }
}

struct PrimaryActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let enabled: Bool
    var tint: Color = .accentColor
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(enabled ? 0.18 : 0.1))

                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(enabled ? .white : .secondary)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(enabled ? .white.opacity(0.9) : .secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(enabled ? .white.opacity(0.95) : .secondary.opacity(0.8))
            }
            .foregroundColor(enabled ? .white : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: enabled
                                ? [tint.opacity(0.98), tint.opacity(0.78)]
                                : [Color.secondary.opacity(0.14), Color.secondary.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        enabled ? Color.white.opacity(0.88) : Color.secondary.opacity(0.18),
                        lineWidth: enabled ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: tint.opacity(enabled ? 0.28 : 0), radius: enabled ? 12 : 0, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.78)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(UIColor.separator).opacity(0.25), lineWidth: 1)
        )
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

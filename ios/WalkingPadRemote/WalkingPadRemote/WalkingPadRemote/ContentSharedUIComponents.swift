import SwiftUI

enum FocusStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.67, blue: 0.40, alpha: 1)
            : UIColor(red: 0.70, green: 0.28, blue: 0, alpha: 1)
    })
    static let actionText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.06, blue: 0, alpha: 1)
            : .white
    })
    static let stop = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.45, blue: 0.51, alpha: 1)
            : UIColor(red: 0.75, green: 0.16, blue: 0.21, alpha: 1)
    })
    static let secondaryText = Color(uiColor: UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.72 : 0.32, alpha: 1)
    })
    static let cornerRadius: CGFloat = 24
}

struct FocusActionStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(isEnabled ? FocusStyle.actionText : Color.secondary)
            .background(
                isEnabled ? (destructive ? FocusStyle.stop : FocusStyle.accent) : Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FocusStyle.cornerRadius, style: .continuous)
                .fill(FocusStyle.surface)
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
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()

                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

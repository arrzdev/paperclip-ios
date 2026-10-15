import SwiftUI

/// A row of two texts (title and date, label and identifier): side by side,
/// stacked from the accessibility text sizes up so nothing is cut.
struct AdaptiveRow<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 2) {
                leading
                trailing
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                leading
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

/// Buttons side by side when they fit, else one under the other.
struct ButtonRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

/// "Running", "Paused", …: a coloured dot that VoiceOver reads as the status.
struct StatusDot: View {
    let color: Color
    let label: String
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityLabel(label)
    }
}

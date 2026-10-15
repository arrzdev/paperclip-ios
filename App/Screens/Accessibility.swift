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

/// An icon and a title for list rows, in place of `Label`: the accessibility
/// audit reports `Label` rows as clipped and not scaling with the text size.
/// The icon column grows with the text; the title wraps instead of cutting.
struct RowLabel: View {
    let title: String
    let systemImage: String
    /// False for a row that sets its own colour (the icon then follows it).
    var tintsIcon = true
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    init(_ title: String, systemImage: String, tintsIcon: Bool = true) {
        self.title = title
        self.systemImage = systemImage
        self.tintsIcon = tintsIcon
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if tintsIcon {
            Image(systemName: systemImage).foregroundStyle(.tint)
        } else {
            Image(systemName: systemImage)
        }
    }
}

/// A list section header or footer in the stronger secondary colour (the
/// system one fails the contrast audit).
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .foregroundStyle(Color.secondaryText)
    }
}

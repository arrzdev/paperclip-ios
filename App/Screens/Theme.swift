import SwiftUI
import UIKit

/// Colours that pass the 4.5:1 text contrast of the accessibility audit, in
/// light and dark mode. The system ones they replace (`.secondary`, system
/// blue and red) fall short on small text. UIKit only for the light / dark
/// pair: SwiftUI has no dynamic colour without an asset catalog.
extension Color {
    /// The app tint: a darker blue in light mode (6.8:1 on white, and white
    /// text on it); system blue in dark mode.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .systemBlue
            : UIColor(red: 0, green: 0x58 / 255, blue: 0xB8 / 255, alpha: 1)
    })

    /// Secondary text: stronger than `.secondary` (about 5.4:1 on the grouped
    /// background in light mode, 7.6:1 on a dark row).
    static let secondaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255, alpha: 1)
            : UIColor(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
    })

    /// Behind white badge text (5.4:1); system red is 3.6:1.
    static let badge = Color(red: 0xD7 / 255, green: 0, blue: 0x15 / 255)
}

import SwiftUI
import UIKit

/// CrashSafe brand palette.
///
/// Two kinds of colors:
/// - **Fills** (`blue`, `red`, `green`) are fixed and dark enough for white text (≥ 4.5:1) in both modes.
/// - **Ink** colors (`blueInk`, `redInk`, …) adapt so text and icons stay ≥ 4.5:1 against the background.
enum Brand {
    // MARK: Core
    /// Pulse Blue — the one accent. Fill for primary actions.
    static let blue = Color(hex: 0x2563EB)
    /// Signal Teal — the greenish secondary accent, paired with `blue` in gradients.
    /// Dark enough for white text (≈ 4.9:1).
    static let teal = Color(hex: 0x0E7C86)
    /// Night navy — the brand's dark canvas.
    static let navy = Color(hex: 0x0B1426)

    // MARK: Status fills (white text)
    static let red = Color(hex: 0xDC2626)
    static let green = Color(hex: 0x15803D)
    /// Amber takes black text.
    static let amber = Color(hex: 0xF59E0B)

    // MARK: Ink (adaptive text/icon colors)
    static let blueInk = Color(light: 0x1D4ED8, dark: 0x7FA8FF)
    static let redInk = Color(light: 0xB91C1C, dark: 0xFF8A80)
    static let greenInk = Color(light: 0x15803D, dark: 0x4ADE80)
    static let amberInk = Color(light: 0xB45309, dark: 0xFBBF24)
    static let tealInk = Color(light: 0x0F766E, dark: 0x5EEAD4)

    // MARK: Surfaces
    static let background = Color(light: 0xF5F5F7, dark: 0x05080F)
    static let surface = Color(light: 0xFFFFFF, dark: 0x0F1729)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x172036)
    static let fieldFill = Color(light: 0xE9E9EE, dark: 0x1A2338)
    static let stroke = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)

    // MARK: Text
    static let textPrimary = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    /// 4.9:1 on `background` in light mode (Apple's #86868b is only 3.5:1).
    static let textSecondary = Color(light: 0x6E6E73, dark: 0xA1A7B5)

}

/// Spacing rhythm from the design system (4 / 8 / 16 / 24 / 48).
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 48
}

enum Radius {
    static let card: CGFloat = 20
    static let field: CGFloat = 14
    static let small: CGFloat = 12
}

// `nonisolated`: UIKit resolves dynamic colors on SwiftUI's async render thread,
// so these must not inherit the module's default MainActor isolation.
nonisolated extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }

    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(uiColor: UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkAlpha)
                : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

nonisolated extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

import SwiftUI
import UIKit

/// CrashSafe "Pulse" brand palette: warm charcoal surfaces, a calm steel-blue accent, amber for caution.
///
/// The app renders in dark mode (see `RootView`); light values are kept so previews and
/// system sheets still read correctly.
/// - **Fills** (`blue`, `red`, `green`) are dark enough for white text (≥ 4.5:1).
/// - **Ink** colors (`blueInk`, `redInk`, …) are for text and icons on the charcoal surfaces (≥ 4.5:1).
enum Brand {
    // MARK: Core
    /// Pulse steel blue — the one accent. Fill for primary actions (white text ≈ 5.4:1).
    static let blue = Color(hex: 0x4C6C93)
    /// Muted slate-teal secondary accent (white text ≈ 5:1).
    static let teal = Color(hex: 0x3F6670)
    /// Night canvas used by full-screen alerts.
    static let navy = Color(hex: 0x161514)

    // MARK: Status fills (white text)
    static let red = Color(hex: 0xC8322B)
    static let green = Color(hex: 0x2E7D4F)
    /// Amber takes black text.
    static let amber = Color(hex: 0xE9A23B)

    // MARK: Ink (adaptive text/icon colors)
    static let blueInk = Color(light: 0x2F5583, dark: 0x9DB8E0)
    static let redInk = Color(light: 0xB42318, dark: 0xFF8F85)
    static let greenInk = Color(light: 0x1F7A45, dark: 0x4FD68C)
    static let amberInk = Color(light: 0xA15C07, dark: 0xF0B04E)
    static let tealInk = Color(light: 0x2C5F69, dark: 0x8CC3CC)

    // MARK: Surfaces
    static let background = Color(light: 0xF4F3F1, dark: 0x121212)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1D1D1D)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x262626)
    static let fieldFill = Color(light: 0xE9E8E5, dark: 0x2A2A2A)
    static let stroke = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.07)

    // MARK: Text
    static let textPrimary = Color(light: 0x1C1B1A, dark: 0xF2F2F2)
    /// ≥ 4.5:1 on `surface` in both modes.
    static let textSecondary = Color(light: 0x66635F, dark: 0xA3A3A3)

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

import SwiftUI

/// Legacy names kept so older call sites read naturally; everything maps to `Brand`.
enum Theme {
    static let accent = Brand.blueInk
    static let danger = Brand.redInk
    static let emergencyFill = Brand.red
    static let safeFill = Brand.green

    /// Minimum height for primary actions (well above Apple's 44pt minimum).
    static let bigTapTarget: CGFloat = 56
    static let cornerRadius: CGFloat = Radius.card
    static let spacing: CGFloat = Space.md
}

// MARK: - Buttons

/// Pill-shaped button (Apple style). Kinds share one shape so screens have one visual language.
struct PillButtonStyle: ButtonStyle {
    enum Kind {
        case primary, danger, safe, dark, secondary, ghost
    }

    var kind: Kind = .primary
    var height: CGFloat = Theme.bigTapTarget
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, Space.lg)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(Brand.blueInk.opacity(0.35), lineWidth: 1.5)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger, .safe: .white
        case .dark: colorScheme == .dark ? .black : .white
        case .secondary, .ghost: Brand.blueInk
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Brand.blue)
        case .danger: AnyShapeStyle(Brand.red)
        case .safe: AnyShapeStyle(Brand.green)
        case .dark: AnyShapeStyle(colorScheme == .dark ? Color.white : Color.black)
        case .secondary: AnyShapeStyle(Brand.blueInk.opacity(0.08))
        case .ghost: AnyShapeStyle(Color.clear)
        }
    }

}

extension ButtonStyle where Self == PillButtonStyle {
    static var primary: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var secondary: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    static func pill(_ kind: PillButtonStyle.Kind, height: CGFloat = Theme.bigTapTarget) -> PillButtonStyle {
        PillButtonStyle(kind: kind, height: height)
    }
}

/// Subtle press feedback for custom tappable rows and cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Surfaces

struct CardModifier: ViewModifier {
    var padding: CGFloat = Space.md
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Brand.stroke))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 16, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = Space.md) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

/// Rounded container used for dashboard cards.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .card()
    }
}

/// Screen background: brand canvas with a soft blue glow at the top in dark mode.
struct BrandBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Brand.background
            .ignoresSafeArea()
    }
}

// MARK: - Small components

/// Colored circle with an SF Symbol, used in lists (as in the design mockups).
struct IconBadge: View {
    let systemName: String
    var tint: Color = Brand.blue
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Small capsule label for statuses.
struct StatusChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = Brand.blueInk

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct SectionHeader: View {
    let title: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Brand.textPrimary)
            Spacer()
            if let action {
                Button(action.title, action: action.run)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
            }
        }
        .padding(.horizontal, Space.xs)
    }
}

/// Label + value status row with a colored SF Symbol.
struct StatusRow: View {
    let systemImage: String
    let title: String
    let value: String
    var tint: Color = Brand.textSecondary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Brand.textSecondary)
                Text(value).font(.body.weight(.medium)).foregroundStyle(Brand.textPrimary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline error message shown under form fields and at the top of forms.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(Brand.redInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Brand.redInk.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .accessibilityLabel("Error: \(message)")
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Motion

/// Fade-up entrance (from the design system: 20pt rise, ease-out curve), staggered by `delay`.
struct FadeUpModifier: ViewModifier {
    let delay: Double
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 20)
            .onAppear {
                withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.55).delay(delay)) { visible = true }
            }
    }
}

extension View {
    func fadeUp(delay: Double = 0) -> some View {
        modifier(FadeUpModifier(delay: delay))
    }
}

/// Expanding rings behind an element (the "pulse" motif).
struct PulseRings: View {
    var color: Color = Brand.blue
    var count = 3
    var active = true
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .scaleEffect(animate ? 1.9 : 1)
                    .opacity(animate ? 0 : 0.8)
                    .animation(
                        active ? .easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(index) * 0.7) : .default,
                        value: animate
                    )
            }
        }
        .onAppear { animate = active }
        .onChange(of: active) { _, new in animate = new }
        .accessibilityHidden(true)
    }
}

#Preview("Design system") {
    ScrollView {
        VStack(spacing: 16) {
            Button("Start a trip") {}.buttonStyle(.primary)
            Button("I need help") {}.buttonStyle(.pill(.danger))
            Button("I'm OK") {}.buttonStyle(.pill(.safe))
            Button("Secondary") {}.buttonStyle(.secondary)
            HStack {
                IconBadge(systemName: "cross.fill", tint: Brand.red)
                IconBadge(systemName: "shield.fill", tint: Brand.blue)
                IconBadge(systemName: "car.fill", tint: Brand.amber)
                StatusChip(text: "Online", systemImage: "wifi")
            }
            Card {
                StatusRow(systemImage: "car.fill", title: "Current trip", value: "Seattle → Spokane", tint: Brand.blueInk)
            }
            ErrorBanner(message: "That password is incorrect.")
        }
        .padding()
    }
    .background(BrandBackground())
}

/// Friendly placeholder for an empty list: tinted icon, title, one line of help.
struct EmptyStateCard: View {
    let systemImage: String
    let title: String
    let message: String
    var tint: Color = Brand.blue

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.headline)
                .foregroundStyle(Brand.textPrimary)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.lg)
        .padding(.horizontal, Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Brand.textSecondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
    }
}

/// Fades content out under the status bar on scrolling screens with a hidden nav bar.
struct StatusBarScrim: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            GeometryReader { proxy in
                Brand.background
                    .frame(height: proxy.safeAreaInsets.top)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func statusBarScrim() -> some View { modifier(StatusBarScrim()) }
}

enum PhoneFormat {
    /// "2065550100" → "(206) 555-0100"; other formats are returned unchanged.
    static func display(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") { digits.removeFirst() }
        guard digits.count == 10, !raw.contains("+") || raw.hasPrefix("+1") else { return raw }
        let d = Array(digits)
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}

extension View {
    /// Content scrolling under the nav bar blurs out instead of colliding with the back button.
    @ViewBuilder
    func softTopEdge() -> some View {
        if #available(iOS 26, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self.toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
    }
}

/// Safety disclaimer (App Review 1.4.1): CrashSafe helps, but it isn't an emergency service.
struct SafetyNotice: View {
    var body: some View {
        Label {
            Text("CrashSafe isn't an emergency service and doesn't replace 911 or your iPhone's Crash Detection. Crash detection can miss crashes or trigger by mistake. Driving advice is general guidance, not a guarantee of safety.")
                .font(.footnote)
                .foregroundStyle(Brand.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Brand.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal normally; switches to vertical at accessibility text sizes (HIG: Dynamic Type layouts).
struct AdaptiveStack<Content: View>: View {
    var spacing: CGFloat = Space.md
    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: horizontalAlignment, spacing: spacing) { content }
                .frame(maxWidth: .infinity, alignment: Alignment(horizontal: horizontalAlignment, vertical: .center))
        } else {
            HStack(alignment: verticalAlignment, spacing: spacing) { content }
        }
    }
}

/// Settings-style row label with a fixed-width icon so rows line up.
struct RowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title).foregroundStyle(Brand.textPrimary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Brand.textPrimary)
                .frame(width: 28)
        }
    }
}

// MARK: - Pulse brand pieces

/// "〜 P U L S E" wordmark: heartbeat glyph plus letter-spaced name.
struct PulseWordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Brand.blueInk)
            Text("PULSE")
                .font(.title3.weight(.medium))
                .tracking(6)
                .foregroundStyle(Brand.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pulse")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Flat-color illustration of a mountain highway at dusk (lake, pines, warm horizon).
/// Drawn in code so it stays crisp at any size and needs no bundled photos.
struct ScenicRoadArt: View {
    var showsCar = true

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func rect(_ y0: Double, _ y1: Double, _ hex: UInt32) {
                context.fill(Path(CGRect(x: 0, y: h * y0, width: w, height: h * (y1 - y0) + 1)), with: .color(Color(hex: hex)))
            }
            func poly(_ points: [(Double, Double)], _ hex: UInt32) {
                var path = Path()
                path.addLines(points.map { CGPoint(x: $0.0 * w, y: $0.1 * h) })
                path.closeSubpath()
                context.fill(path, with: .color(Color(hex: hex)))
            }
            func pine(_ x: Double, _ base: Double, _ height: Double, _ hex: UInt32) {
                let tw = height * h * 0.36 / w
                for tier in 0..<3 {
                    let top = base - height * (1 - Double(tier) * 0.22)
                    let bottom = base - height * Double(2 - tier) * 0.18
                    let half = tw * (0.55 + Double(tier) * 0.25)
                    poly([(x, top), (x + half, bottom), (x - half, bottom)], hex)
                }
            }

            // Sky in stepped bands, warming toward the horizon.
            rect(0, 0.2, 0x26272E)
            rect(0.2, 0.31, 0x3A3437)
            rect(0.31, 0.4, 0x6A4A3F)
            rect(0.4, 0.47, 0xA9663F)
            rect(0.47, 0.56, 0xD98E52)
            context.fill(Path(ellipseIn: CGRect(x: w * 0.68, y: h * 0.45, width: h * 0.13, height: h * 0.13)),
                         with: .color(Color(hex: 0xF6CB86)))
            for (x, y, cw) in [(0.05, 0.08, 0.34), (0.48, 0.14, 0.3), (0.2, 0.25, 0.22), (0.72, 0.3, 0.26)] {
                context.fill(Path(roundedRect: CGRect(x: w * x, y: h * y, width: w * cw, height: h * 0.05), cornerRadius: h * 0.025),
                             with: .color(Color(hex: 0x2E2B2F)))
            }

            // Ranges, lake and far shore.
            poly([(0, 0.6), (0, 0.5), (0.12, 0.44), (0.22, 0.5), (0.34, 0.41), (0.46, 0.5), (0.56, 0.45),
                  (0.66, 0.52), (0.8, 0.43), (0.92, 0.5), (1, 0.46), (1, 0.6)], 0x5A4D54)
            poly([(0, 0.64), (0, 0.55), (0.1, 0.52), (0.2, 0.57), (0.3, 0.51), (0.42, 0.58), (0.58, 0.55),
                  (0.74, 0.59), (0.88, 0.53), (1, 0.57), (1, 0.64)], 0x39343C)
            rect(0.6, 0.68, 0x6E5658)
            context.fill(Path(CGRect(x: w * 0.66, y: h * 0.62, width: w * 0.1, height: h * 0.012)), with: .color(Color(hex: 0xE2A066)))
            context.fill(Path(CGRect(x: w * 0.69, y: h * 0.645, width: w * 0.05, height: h * 0.01)), with: .color(Color(hex: 0xC98A57)))
            for i in 0..<14 { pine(0.38 + Double(i) * 0.05, 0.61, 0.05 + Double(i % 3) * 0.015, 0x22272A) }

            // Ground, road and guardrail.
            rect(0.67, 1, 0x1C1F1D)
            poly([(0.06, 1), (0.56, 0.67), (0.62, 0.67), (1.04, 1)], 0x333336)
            poly([(0.76, 1), (0.6, 0.67), (0.605, 0.67), (0.775, 1)], 0x8C8C8C)
            for i in 0..<5 {
                let t0 = 0.69 + Double(i) * 0.065, t1 = t0 + 0.035
                let x0 = 0.59 - (t0 - 0.67) * 0.62, x1 = 0.59 - (t1 - 0.67) * 0.62
                let half0 = 0.002 + (t0 - 0.67) * 0.02, half1 = 0.002 + (t1 - 0.67) * 0.02
                poly([(x0 - half0, t0), (x0 + half0, t0), (x1 + half1, t1), (x1 - half1, t1)], 0xD9C28C)
            }
            poly([(0.88, 1), (0.63, 0.66), (0.633, 0.657), (0.895, 0.99)], 0xA3A3A3)

            // Foreground pines.
            for (x, height) in [(0.03, 0.62), (0.11, 0.48), (0.19, 0.36), (0.27, 0.24), (0.95, 0.3)] {
                pine(x, 0.72 + height * 0.25, height, 0x141815)
            }

            if showsCar {
                let cx = w * 0.4, cy = h * 0.79, cw = w * 0.16
                let ch = cw * 0.42
                context.fill(Path(roundedRect: CGRect(x: cx - cw * 0.38, y: cy - ch * 1.05, width: cw * 0.76, height: ch * 0.6),
                                  cornerRadius: ch * 0.2), with: .color(Color(hex: 0x3B4148)))
                context.fill(Path(roundedRect: CGRect(x: cx - cw * 0.31, y: cy - ch * 0.95, width: cw * 0.62, height: ch * 0.36),
                                  cornerRadius: ch * 0.12), with: .color(Color(hex: 0x15181C)))
                context.fill(Path(roundedRect: CGRect(x: cx - cw / 2, y: cy - ch * 0.5, width: cw, height: ch * 0.62),
                                  cornerRadius: ch * 0.18), with: .color(Color(hex: 0x4A5058)))
                for side in [-1.0, 1.0] {
                    context.fill(Path(roundedRect: CGRect(x: cx + side * cw * 0.36 - cw * 0.1, y: cy - ch * 0.38, width: cw * 0.2, height: ch * 0.12),
                                      cornerRadius: 2), with: .color(Color(hex: 0xFF5A4A)))
                    context.fill(Path(roundedRect: CGRect(x: cx + side * cw * 0.34 - cw * 0.08, y: cy + ch * 0.08, width: cw * 0.16, height: ch * 0.26),
                                      cornerRadius: 3), with: .color(Color(hex: 0x0D0E10)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

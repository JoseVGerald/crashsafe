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
            .shadow(color: shadowColor, radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 2 : 6)
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
        case .primary: AnyShapeStyle(Brand.heroGradient)
        case .danger: AnyShapeStyle(Brand.red)
        case .safe: AnyShapeStyle(Brand.green)
        case .dark: AnyShapeStyle(colorScheme == .dark ? Color.white : Color.black)
        case .secondary: AnyShapeStyle(Brand.blueInk.opacity(0.08))
        case .ghost: AnyShapeStyle(Color.clear)
        }
    }

    private var shadowColor: Color {
        switch kind {
        case .primary: Brand.blue.opacity(0.28)
        case .danger: Brand.red.opacity(0.28)
        case .safe: Brand.green.opacity(0.25)
        default: .clear
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
        ZStack(alignment: .top) {
            Brand.background
            if colorScheme == .dark {
                RadialGradient(colors: [Brand.blue.opacity(0.24), .clear], center: .top, startRadius: 0, endRadius: 420)
                    .frame(height: 420)
                RadialGradient(colors: [Brand.teal.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 460)
            } else {
                RadialGradient(colors: [Brand.teal.opacity(0.06), .clear], center: .topTrailing, startRadius: 0, endRadius: 380)
            }
        }
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
            .background(tint.gradient, in: Circle())
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
                LinearGradient(colors: [Brand.background, Brand.background.opacity(0.85), Brand.background.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: proxy.safeAreaInsets.top + 14)
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

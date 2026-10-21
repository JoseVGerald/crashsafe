import SwiftUI

/// Short animated splash shown while the saved session is restored.
struct SplashView: View {
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Theme.accent.ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 3)
                        .frame(width: 150, height: 150)
                        .scaleEffect(pulse ? 1.35 : 0.9)
                        .opacity(pulse ? 0 : 1)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 84, weight: .semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(appeared ? 1 : 0.6)
                }
                VStack(spacing: 6) {
                    Text("CrashSafe")
                        .font(.largeTitle.bold())
                    Text("Help for what happens next.")
                        .font(.headline)
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CrashSafe. Help for what happens next.")
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) { appeared = true }
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

#Preview {
    SplashView()
}

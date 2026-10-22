import SwiftData
import SwiftUI

/// CarPlay-style driving mode: a glanceable, landscape-friendly dashboard that keeps monitoring
/// (accelerometer + GPS + time of day) and coaches the driver in the style their profile asks for.
///
/// Proof of concept — this runs on the phone. Shipping on a real CarPlay screen needs Apple's
/// CarPlay entitlement and a CPTemplate scene (see README → CarPlay).
struct CarPlayModeView: View {
    let user: AuthUser
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [Profile]

    @State private var startedLive = false

    init(user: AuthUser) {
        self.user = user
        let id = user.id
        _profiles = Query(filter: #Predicate<Profile> { $0.ownerID == id })
    }

    private var profile: Profile? { profiles.first }
    private var snapshot: DrivingSnapshot { env.driving.snapshot }
    private var isNight: Bool { env.driving.scenario?.isNight ?? env.conditions.isNight }
    private var advice: DrivingAdvice { DrivingAdvice.make(weather: env.conditions.weather, isNight: isNight) }
    private var comparison: DrivingComparison {
        DrivingComparison.make(snapshot: snapshot, advice: advice, isDriving: env.driving.isActive)
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height
            ZStack {
                background
                VStack(spacing: 14) {
                    topBar
                    conditionsRow
                    if wide {
                        HStack(spacing: 14) {
                            speedPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                            VStack(spacing: 14) {
                                coachPanel
                                sensorsPanel
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        speedPanel
                        coachPanel
                        sensorsPanel
                        Spacer(minLength: 0)
                        if env.driving.scenario != nil { scenarioBar }
                    }
                }
                .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    // MARK: Panels

    private var background: some View {
        Brand.background
            .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Exit CarPlay mode")

            VStack(alignment: .leading, spacing: 2) {
                Text("CarPlay").font(.headline)
                Text(env.driving.scenario.map { "Demo · \($0.title)" } ?? (env.driving.mode == .live ? liveStatus : "Starting…"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Button {
                env.coach.speaks.toggle()
            } label: {
                Image(systemName: env.coach.speaks ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.headline)
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .accessibilityLabel(env.coach.speaks ? "Mute Pulse" : "Unmute Pulse")
        }
        .foregroundStyle(.white)
    }

    /// Where the live data is coming from, in plain words.
    private var liveStatus: String {
        if let segment = snapshot.roadSegment {
            let extras = snapshot.roadFeatures.labels.map { " · \($0)" }.joined()
            return "Live · \(segment.title)" + (snapshot.roadName.map { " · \($0)" } ?? "") + extras
        }
        if let road = snapshot.roadName { return "Live · \(road)" }
        return env.sensors.hasMotionHardware ? "Live · GPS + motion sensors" : "Live · GPS"
    }

    private var speedLimitStatus: String {
        switch env.driving.speedLimits?.status {
        case .loading: "FINDING"
        case .failed: "NO DATA"
        default: "LIMIT"
        }
    }

    private var conditionsRow: some View {
        HStack(spacing: 8) {
            chip(env.driving.scenario?.demoClock ?? Date.now.formatted(date: .omitted, time: .shortened),
                 icon: isNight ? "moon.fill" : "sun.max.fill")
            if let weather = env.conditions.weather {
                chip("\(Int(weather.temperatureF))° \(weather.condition.label)", icon: weather.condition.systemImage(isDay: weather.isDay))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    private var speedPanel: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * min(snapshot.speedMPH / 90, 1))
                    .stroke(statusColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.spring(response: 0.6), value: snapshot.speedMPH)
                VStack(spacing: 0) {
                    Text("\(Int(snapshot.speedMPH))")
                        .font(.system(size: 84, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                        .animation(.default, value: Int(snapshot.speedMPH))
                    Text("mph").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: 260, maxHeight: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int(snapshot.speedMPH)) miles per hour")

            HStack(spacing: 10) {
                if let limit = snapshot.speedLimitMPH {
                    SpeedSign(value: Int(limit), label: snapshot.speedLimitIsPosted ? "LIMIT" : "TYPICAL")
                } else if env.driving.mode == .live {
                    SpeedSign(value: nil, label: speedLimitStatus)
                }
                if let recommended = comparison.recommendedMaxMPH {
                    SpeedSign(value: Int(recommended), label: "SAFE NOW", tint: statusColor)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder
    private var coachPanel: some View {
        let current = env.coach.message ?? CoachingMessage(
            title: "Pulse is riding along",
            body: "I'll speak up if your driving doesn't match the road, the weather or the time of day.",
            severity: .positive)
        HStack(alignment: .top, spacing: 14) {
            PulseAvatar(size: 46, active: current.severity != .positive)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(current.title).font(.title3.bold())
                    Spacer()
                    StatusChip(text: profile?.coachingStyle == .emotional ? "Heart" : "Facts",
                               systemImage: profile?.coachingStyle.systemImage, tint: .white)
                }
                Text(current.body)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(severityColor(current.severity).opacity(0.22), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(severityColor(current.severity).opacity(0.5)))
        .id(env.coach.messageID)
        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: env.coach.messageID)
    }

    private var sensorsPanel: some View {
        HStack(spacing: 10) {
            sensorTile(icon: "waveform.path.ecg", title: "g-force", value: String(format: "%.2f g", snapshot.currentG)) {
                GForceSparkline(values: env.driving.gHistory)
                    .stroke(Brand.tealInk, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    .frame(height: 30)
            }
            sensorTile(icon: "exclamationmark.octagon.fill", title: "Brakes", value: "\(snapshot.hardBrakes)") {
                EmptyView()
            }
            sensorTile(icon: environmentIcon, title: "Road",
                       value: snapshot.roadSegment?.title ?? (snapshot.environment == .forest ? "Wooded" : snapshot.environment.label.capitalized)) {
                EmptyView()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
    }

    private var scenarioBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DriveScenario.allCases) { scenario in
                    Button {
                        env.driving.startDemo(scenario)
                        env.conditions.override(with: scenario.weather)
                    } label: {
                        Label(scenario.title, systemImage: scenario.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .foregroundStyle(env.driving.scenario == scenario ? .black : .white)
                            .background(env.driving.scenario == scenario ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)),
                                        in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func chip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(.white.opacity(0.1), in: Capsule())
    }

    private func sensorTile<Extra: View>(icon: String, title: String, value: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            extra()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var environmentIcon: String {
        switch snapshot.environment {
        case .forest: "tree.fill"
        case .highway: "road.lanes"
        case .city: "building.2.fill"
        }
    }

    private var statusColor: Color {
        switch comparison.status {
        case .noData, .onTrack: Color(hex: 0x22C55E)
        case .caution: Brand.amber
        case .tooFast: Color(hex: 0xEF4444)
        }
    }

    private func severityColor(_ severity: CoachingMessage.Severity) -> Color {
        switch severity {
        case .positive: Color(hex: 0x22C55E)
        case .caution: Brand.amber
        case .warning: Color(hex: 0xEF4444)
        }
    }

    // MARK: Behaviour

    private func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        // Always real data: GPS speed, the posted limit for the road (OpenStreetMap) and live weather.
        // Demo drives only run if one was started from Profile → Testing.
        if !env.driving.isActive {
            env.driving.startLive(background: profile?.autoDetectDrives ?? true)
            startedLive = true
        }
    }

    private func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        if startedLive { env.driving.stop() }
    }
}

/// US-style speed sign.
private struct SpeedSign: View {
    /// nil while the limit is being looked up.
    let value: Int?
    let label: String
    var tint: Color = .white

    var body: some View {
        VStack(spacing: 0) {
            Text(label).font(.system(size: 10, weight: .heavy)).tracking(0.5)
            Text(value.map(String.init) ?? "–").font(.system(size: 28, weight: .heavy, design: .rounded)).contentTransition(.numericText())
        }
        .foregroundStyle(.black)
        .frame(width: 78, height: 64)
        .background(tint == .white ? Color.white : tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: 3).strokeBorder(.black, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

/// Recent accelerometer magnitudes as a line.
nonisolated private struct GForceSparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let maxValue = max(values.max() ?? 0, 0.6)
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * Double(index) / Double(values.count - 1)
            let y = rect.maxY - rect.height * min(value / maxValue, 1)
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

#Preview {
    CarPlayModeView(user: PreviewData.user)
        .environment(PreviewData.environment())
        .modelContainer(PreviewData.container())
}

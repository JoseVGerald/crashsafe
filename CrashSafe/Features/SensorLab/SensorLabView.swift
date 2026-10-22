import SwiftUI

/// Profile → Testing → Sensor lab: everything the phone's motion sensors and GPS measure, live —
/// how it's tilted, how hard it's shaken or turned, quick jolts, speed — plus what the crash detector
/// would make of it, recordings to share, and replays of real crashes and everyday motion.
struct SensorLabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private var lab: SensorLabModel { env.sensorLab }

    var body: some View {
        NavigationStack {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !lab.isRunning)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.md) {
                        status
                        replayCard
                        tiltCard
                        motionCard(now: context.date)
                        rotationCard
                        joltsCard
                        crashCheckCard
                        speedCard
                        recordCard(now: context.date)
                        Text("Bundled clips: real walking and jogging from MotionSense (MIT license, Malekzadeh et al.); the real crash is NHTSA crash test 7605 (public domain). Generated events use simple physics with random speeds, mounts and noise.")
                            .font(.caption)
                            .foregroundStyle(Brand.textSecondary)
                            .padding(.horizontal, Space.xs)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.bottom, Space.lg)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(BrandBackground())
            .navigationTitle("Sensor lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset", systemImage: "arrow.counterclockwise") { lab.resetPeaks() }
                }
            }
        }
        .onAppear { lab.start() }
        .onDisappear { lab.stop() }
    }

    // MARK: Status

    private var status: some View {
        let health = env.sensors.health
        let (text, icon, tint): (String, String, Color) = if lab.isReplaying {
            ("Replaying", "play.circle.fill", Brand.amberInk)
        } else {
            switch health.state {
            case .active: ("Live", "dot.radiowaves.left.and.right", Brand.greenInk)
            case .unavailable: ("No motion sensor here", "iphone.slash", Brand.textSecondary)
            case .permissionDenied: ("Motion access off", "hand.raised.fill", Brand.redInk)
            case .starting: ("Starting…", "hourglass", Brand.textSecondary)
            default: ("Paused", "pause.circle", Brand.amberInk)
            }
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusChip(text: text, systemImage: icon, tint: tint)
                Spacer()
                Text("\(Int(health.requestedHz)) Hz asked · \(health.measuredHz.formatted(.number.precision(.fractionLength(1)))) Hz measured")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Brand.textSecondary)
            }
            Text("Gaps \(health.motionGaps) · rejected \(health.rejectedMotionSamples) motion, \(health.rejectedLocationSamples) GPS")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Brand.textSecondary)
            if let current = env.intelligence.current {
                let best = current.probabilities.indices.max { current.probabilities[$0] < current.probabilities[$1] }
                let mode = best.flatMap(TransportClass.init(rawValue:))
                Label("Moving like: \(mode?.title ?? "–") \(Int((current.probability * 100).rounded()))%\(current.transportClass == nil ? " (not sure yet)" : "")",
                      systemImage: mode?.systemImage ?? "questionmark.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
            }
            if health.state == .unavailable && !lab.isReplaying {
                Text("This device has no motion sensor (the simulator doesn't). Replay a clip below to feed the app real or generated motion.")
                    .font(.footnote)
                    .foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Space.sm)
    }

    // MARK: Replay

    private var replayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Replay").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                if lab.isReplaying {
                    Button("Stop", systemImage: "stop.fill") { lab.stopReplay() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.redInk)
                }
            }
            if let title = lab.replayTitle {
                Text(title).font(.footnote).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Feeds motion into the app as if the phone sensed it: through the same pipeline, in real time.")
                    .font(.footnote).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: Binding(get: { lab.replayTriggersCheckIn }, set: { lab.replayTriggersCheckIn = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also run the real check-in").font(.subheadline.weight(.medium)).foregroundStyle(Brand.textPrimary)
                    Text(lab.replayTriggersCheckIn
                         ? "During a watched drive, a replayed crash starts the real \u{201C}Are you okay?\u{201D} flow, and contacts are alerted if no one answers."
                         : "Off: replays only show here and never start a check-in or alert anyone.")
                        .font(.caption).foregroundStyle(lab.replayTriggersCheckIn ? Brand.amberInk : Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Brand.red)
            Menu {
                Section("Real data") {
                    Button(RealCrashPulse.title, systemImage: "car.side.rear.and.collision.and.car.side.front") { lab.play(.realCrash) }
                    ForEach(SensorLabModel.bundledClips, id: \.name) { clip in
                        Button(clip.title, systemImage: clip.name.contains("jog") ? "figure.run" : "figure.walk") { lab.play(.bundled(clip.name)) }
                    }
                }
                Section("Generated crashes") {
                    ForEach(SensorScenario.Kind.allCases.filter(\.isCrash), id: \.self) { kind in
                        Button(kind.title) { lab.play(.generated(kind)) }
                    }
                }
                Section("Generated look-alikes") {
                    ForEach(SensorScenario.Kind.allCases.filter { !$0.isCrash }, id: \.self) { kind in
                        Button(kind.title) { lab.play(.generated(kind)) }
                    }
                }
                if !lab.recordings.isEmpty {
                    Section("Your recordings") {
                        ForEach(lab.recordings, id: \.self) { url in
                            Button(url.deletingPathExtension().lastPathComponent, systemImage: "waveform.path") { lab.play(.file(url)) }
                        }
                    }
                }
            } label: {
                Label("Choose a clip", systemImage: "play.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.blueInk)
                    .frame(minHeight: 44)
            }
        }
        .card(padding: Space.md)
    }

    // MARK: Tilt

    private var tiltCard: some View {
        let tilt = lab.tilt
        return VStack(alignment: .leading, spacing: 12) {
            Text("Tilt").font(.headline).foregroundStyle(Brand.textPrimary)
            HStack(alignment: .center, spacing: Space.lg) {
                TiltDial(tilt: tilt)
                    .frame(width: 132, height: 132)
                VStack(alignment: .leading, spacing: 8) {
                    metric("Forward / back", tilt.map { angle($0.pitch, positive: "top up", negative: "top down") })
                    metric("Side to side", tilt.map { angle($0.roll, positive: "right down", negative: "left down") })
                    metric("From flat", tilt.map { "\(Int($0.fromFlat.rounded()))°" + ($0.fromFlat > 150 ? " · face down" : "") })
                }
            }
            Text("The bubble floats to the raised edge; the arrow points down. From the gravity vector Core Motion separates from your own movement.")
                .font(.caption).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: Space.md)
    }

    private func angle(_ degrees: Double, positive: String, negative: String) -> String {
        let d = Int(degrees.rounded())
        return d == 0 ? "0° level" : "\(abs(d))° \(d > 0 ? positive : negative)"
    }

    // MARK: Motion

    private func motionCard(now: Date) -> some View {
        let samples = lab.motion.values
        let latest = samples.last
        let split = latest.map { SensorLabMath.split($0.accelerationG, gravity: $0.gravityG) }
        let threshold = CrashEvaluationConfiguration().candidateG
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Acceleration").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                Text("g, gravity removed · last 5 s").font(.caption).foregroundStyle(Brand.textSecondary)
            }
            AxisGraph(samples: samples, value: { $0.accelerationG }, minimumRange: 1, guides: [1, threshold])
                .frame(height: 140)
            AxisLegend()
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 6) {
                GridRow {
                    metric("Now", latest.map { g($0.accelerationG.magnitude) })
                    metric("Peak", g(lab.peakG))
                    metric("Jerk", "\(Int(lab.tracker.jerk.rounded())) g/s")
                }
                GridRow {
                    metric("Sideways", split.map { g($0.horizontal) })
                    metric("Up / down", split.map { g($0.vertical) })
                    metric("Total", latest.map { g($0.totalAccelerationG.magnitude) })
                }
            }
            Text("Sideways is braking, speeding up and turning, whichever way the phone sits; up/down is bumps and drops. A crash check starts at \(Int(threshold)) g (dashed line). Total reads ~1 g at rest and ~0 in free fall.")
                .font(.caption).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: Space.md)
    }

    private var rotationCard: some View {
        let samples = lab.motion.values
        let rotation = samples.last?.rotationRate
        let threshold = CrashEvaluationConfiguration().rotationRadPerSecond
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rotation (gyroscope)").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                Text("°/s · last 5 s").font(.caption).foregroundStyle(Brand.textSecondary)
            }
            AxisGraph(samples: samples, value: { $0.rotationRate * (180 / .pi) }, minimumRange: 90,
                      guides: [threshold * 180 / .pi])
                .frame(height: 120)
            AxisLegend(names: ("tilt fwd/back", "tilt side", "turn"))
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 6) {
                GridRow {
                    metric("Now", rotation.map { degreesPerSecond($0.magnitude) })
                    metric("Peak", degreesPerSecond(lab.peakRotation))
                    metric("Turning", rotation.map { degreesPerSecond(abs($0.z)) })
                }
            }
            Text("Spinning faster than \(Int(threshold * 180 / .pi))°/s (dashed) counts as rapid rotation in a crash check.")
                .font(.caption).foregroundStyle(Brand.textSecondary)
        }
        .card(padding: Space.md)
    }

    // MARK: Jolts and crash check

    private var joltsCard: some View {
        let now = lab.latest?.uptime ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("Quick changes").font(.headline).foregroundStyle(Brand.textPrimary)
            if lab.jolts.isEmpty {
                Text("Tap the phone, shake it, or drop it on a bed: each jolt over 0.5 g shows up here.")
                    .font(.footnote).foregroundStyle(Brand.textSecondary)
            }
            ForEach(lab.jolts) { jolt in
                HStack(spacing: 10) {
                    Image(systemName: icon(for: jolt.kind)).frame(width: 24).foregroundStyle(tint(for: jolt.kind))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(jolt.kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.textPrimary)
                        Text("\(g(jolt.peakG)) · \(Int((jolt.duration * 1000).rounded())) ms · \(degreesPerSecond(jolt.peakRotation))")
                            .font(.caption.monospacedDigit()).foregroundStyle(Brand.textSecondary)
                    }
                    Spacer()
                    Text("\(Int(max(0, now - jolt.uptime).rounded())) s ago").font(.caption.monospacedDigit()).foregroundStyle(Brand.textSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card(padding: Space.md)
    }

    private var crashCheckCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Crash check").font(.headline).foregroundStyle(Brand.textPrimary)
                Spacer()
                Text("\(lab.assessmentsSeen) examined").font(.caption.monospacedDigit()).foregroundStyle(Brand.textSecondary)
            }
            if let a = lab.lastAssessment {
                let (label, tint): (String, Color) = switch a.decision {
                case .suspectedCrash: ("Would start a check-in", Brand.redInk)
                case .inconclusive: ("Not sure: no check-in", Brand.amberInk)
                case .rejected: ("Not a crash", Brand.greenInk)
                }
                StatusChip(text: label, systemImage: a.decision == .suspectedCrash ? "exclamationmark.triangle.fill" : "checkmark.circle", tint: tint)
                Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 6) {
                    GridRow {
                        metric("Peak", g(a.peakG))
                        metric("Speed change", a.impactDeltaVMPS.map { "\(Int(($0 * 2.23694).rounded())) mph" })
                        metric("Spin", degreesPerSecond(a.peakRotationRadPerSecond))
                    }
                    GridRow {
                        metric("Hit lasted", "\(Int((a.impactDuration * 1000).rounded())) ms")
                        metric("GPS speed drop", a.speedDropMPS.map { "\(Int(($0 * 2.23694).rounded())) mph" } ?? "no GPS")
                        metric("After", a.postImpactRMSG.map { $0 <= 0.15 ? "still" : "moving" })
                    }
                }
                FlowChips(items: a.evidence.map(Self.evidenceTitle) + a.issues.map(Self.issueTitle))
            } else {
                Text("Anything over \(Int(CrashEvaluationConfiguration().candidateG)) g is examined here exactly as during a drive, 3.5 s later. This copy never alerts anyone.")
                    .font(.footnote).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: Space.md)
    }

    static func evidenceTitle(_ e: CrashEvidence) -> String {
        switch e {
        case .sustainedImpact: "Hit lasted"
        case .strongImpact: "Strong hit"
        case .rapidRotation: "Spun"
        case .speedLoss: "GPS speed dropped"
        case .settledAfterImpact: "Still afterward"
        case .possiblePhoneDrop: "Fell first (drop?)"
        case .continuedTravel: "Kept driving"
        case .largeImpactDeltaV: "Crash-sized speed change"
        }
    }

    static func issueTitle(_ i: CrashDataIssue) -> String {
        switch i {
        case .insufficientBaseline: "Too little before"
        case .insufficientPostImpact: "Too little after"
        case .motionGap: "Gap in motion"
        case .missingReliableGPS: "No reliable GPS"
        }
    }

    // MARK: Speed

    private var speedCard: some View {
        let fix = lab.latestFix
        let limit = env.driving.speedLimits?.current
        let fixes = lab.fixes.values
        let heading: Double? = fixes.count >= 2 ? {
            let a = fixes[fixes.count - 2], b = fixes[fixes.count - 1]
            return TransportFeatures.haversine(a.latitude, a.longitude, b.latitude, b.longitude) >= 3
                ? RoadMatcher.bearing(fromLat: a.latitude, lon: a.longitude, toLat: b.latitude, lon: b.longitude) : nil
        }() : nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("Speed (GPS)").font(.headline).foregroundStyle(Brand.textPrimary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fix.map { $0.speedMPS >= 0 ? "\(Int(($0.speedMPS * 2.23694).rounded()))" : "–" } ?? "–")
                    .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Brand.textPrimary)
                Text("mph").font(.title3).foregroundStyle(Brand.textSecondary)
                Spacer()
                if let limit {
                    VStack(spacing: 0) {
                        Text(limit.isPosted ? "LIMIT" : "TYPICAL").font(.caption2.weight(.bold))
                        Text("\(Int(limit.mph))").font(.title2.weight(.bold).monospacedDigit())
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black, lineWidth: 2))
                    .accessibilityLabel("Speed limit \(Int(limit.mph)) miles per hour")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: Space.md, verticalSpacing: 6) {
                GridRow {
                    metric("Speed ±", fix.map { $0.speedAccuracy >= 0 ? "\(($0.speedAccuracy * 2.23694).formatted(.number.precision(.fractionLength(1)))) mph" : "unknown" })
                    metric("Position ±", fix.map { $0.horizontalAccuracy >= 0 ? "\(Int($0.horizontalAccuracy.rounded())) m" : "unknown" })
                    metric("Heading", heading.map { "\(SensorLabMath.compass($0)) \(Int($0.rounded()))°" })
                }
                GridRow {
                    metric("Speeding up", lab.gpsLongitudinalG.map { g($0, signed: true) })
                    metric("Road", limit?.roadName ?? (limit == nil ? nil : "unnamed"))
                    metric("Fix age", fix.map { "\(Int(max(0, ProcessInfo.processInfo.systemUptime - $0.uptime).rounded())) s" })
                }
            }
            Text("GPS speed comes from the Doppler shift of satellite signals, about once a second. Speeding up/slowing down in g is the change between the last two fixes. Limits come from OpenStreetMap.")
                .font(.caption).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: Space.md)
    }

    // MARK: Record

    private func recordCard(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record").font(.headline).foregroundStyle(Brand.textPrimary)
            switch lab.recording {
            case .recording(let until):
                let left = max(0, until - (lab.latest?.uptime ?? until))
                ProgressView(value: SensorLabModel.recordSeconds - left, total: SensorLabModel.recordSeconds) {
                    Text("Recording… \(Int(left.rounded(.up))) s left").font(.subheadline).foregroundStyle(Brand.textPrimary)
                }
                .tint(Brand.red)
                Button("Stop now") { lab.finishRecording() }.font(.subheadline.weight(.semibold)).foregroundStyle(Brand.redInk)
            case .saved(let url):
                Label(url.lastPathComponent, systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(Brand.greenInk)
                HStack(spacing: Space.md) {
                    ShareLink(item: url) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                    Button("Replay", systemImage: "play.fill") { lab.play(.file(url)) }
                    Button("Record again", systemImage: "record.circle") { lab.startRecording() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.blueInk)
            case .idle:
                Button {
                    lab.startRecording()
                } label: {
                    Label("Record \(Int(SensorLabModel.recordSeconds)) s", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.redInk)
                        .frame(minHeight: 44)
                }
                .disabled(!lab.isRunning)
            }
            Text("Saves 100 Hz motion and GPS speed as CSV (no location), to share with your computer or replay here. CSVs copied into the app's Documents/Recordings folder show up under Replay too.")
                .font(.caption).foregroundStyle(Brand.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: Space.md)
    }

    // MARK: Helpers

    private func metric(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Brand.textSecondary)
            Text(value ?? "–").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Brand.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func g(_ value: Double, signed: Bool = false) -> String {
        (signed && value > 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(2))) + " g"
    }

    private func degreesPerSecond(_ radians: Double) -> String { "\(Int((radians * 180 / .pi).rounded()))°/s" }

    private func icon(for kind: Jolt.Kind) -> String {
        switch kind {
        case .crashLevel: "exclamationmark.triangle.fill"
        case .drop: "arrow.down.to.line"
        case .hard: "bolt.fill"
        case .bump: "waveform.path"
        }
    }

    private func tint(for kind: Jolt.Kind) -> Color {
        switch kind {
        case .crashLevel: Brand.redInk
        case .drop: Brand.amberInk
        case .hard: Brand.amberInk
        case .bump: Brand.blueInk
        }
    }
}

// MARK: - Pieces

/// Bubble level plus a "down" arrow, from the gravity vector projected onto the screen.
private struct TiltDial: View {
    let tilt: SensorLabMath.Tilt?

    var body: some View {
        GeometryReader { proxy in
            let r = min(proxy.size.width, proxy.size.height) / 2
            let bubble: (x: Double, y: Double) = tilt?.bubble ?? (x: 0, y: 0)
            ZStack {
                Circle().fill(Brand.fieldFill)
                Circle().strokeBorder(Brand.stroke, lineWidth: 1)
                Circle().stroke(Brand.textSecondary.opacity(0.4), lineWidth: 1).frame(width: r * 0.5, height: r * 0.5)
                Path { p in
                    p.move(to: CGPoint(x: r, y: r * 0.15)); p.addLine(to: CGPoint(x: r, y: r * 1.85))
                    p.move(to: CGPoint(x: r * 0.15, y: r)); p.addLine(to: CGPoint(x: r * 1.85, y: r))
                }
                .stroke(Brand.textSecondary.opacity(0.25), lineWidth: 1)
                // Down arrow: opposite the bubble.
                Path { p in
                    p.move(to: CGPoint(x: r, y: r))
                    p.addLine(to: CGPoint(x: r - bubble.x * r * 0.85, y: r - bubble.y * r * 0.85))
                }
                .stroke(Brand.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Circle()
                    .fill(abs(bubble.x) < 0.05 && abs(bubble.y) < 0.05 ? Brand.green : Brand.blue)
                    .frame(width: r * 0.42, height: r * 0.42)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .position(x: r + bubble.x * r * 0.75, y: r + bubble.y * r * 0.75)
            }
            .frame(width: r * 2, height: r * 2)
        }
        .accessibilityElement()
        .accessibilityLabel(tilt.map { "Tilt: \(Int($0.pitch.rounded())) degrees forward, \(Int($0.roll.rounded())) degrees sideways" } ?? "Tilt unknown")
    }
}

/// Three axes over the last 5 s, scaled to fit, with dashed guide lines at ±each guide value.
private struct AxisGraph: View {
    let samples: [MotionSample]
    let value: (MotionSample) -> SensorVector
    var minimumRange: Double
    var guides: [Double]

    static let colors: [Color] = [Brand.red, Brand.green, Brand.blue]

    var body: some View {
        Canvas { context, size in
            guard let last = samples.last?.uptime else { return }
            let window = 5.0
            let visible = samples.filter { $0.uptime >= last - window }
            let values = visible.map(value)
            let peak = values.map { max(abs($0.x), abs($0.y), abs($0.z)) }.max() ?? 0
            let range = max(minimumRange, peak * 1.15)
            func y(_ v: Double) -> CGFloat { size.height / 2 - CGFloat(v / range) * size.height / 2 }
            func x(_ t: Double) -> CGFloat { CGFloat((t - (last - window)) / window) * size.width }
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: size.height / 2)); axis.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(axis, with: .color(Brand.textSecondary.opacity(0.3)), lineWidth: 1)
            for guide in guides where guide < range {
                for v in [guide, -guide] {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: y(v))); p.addLine(to: CGPoint(x: size.width, y: y(v)))
                    context.stroke(p, with: .color(Brand.textSecondary.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            // Thin out to about one point per pixel.
            let step = max(1, visible.count / max(Int(size.width), 1))
            for (axisIndex, color) in Self.colors.enumerated() {
                var path = Path()
                for i in stride(from: 0, to: visible.count, by: step) {
                    let v = values[i]
                    let component = axisIndex == 0 ? v.x : axisIndex == 1 ? v.y : v.z
                    let point = CGPoint(x: x(visible[i].uptime), y: y(component))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
            context.draw(Text("±\(range.formatted(.number.precision(.fractionLength(range < 10 ? 1 : 0))))").font(.caption2).foregroundStyle(Brand.textSecondary),
                         at: CGPoint(x: 4, y: 2), anchor: .topLeading)
        }
        .background(Brand.fieldFill.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small))
        .accessibilityHidden(true)
    }
}

private struct AxisLegend: View {
    var names: (String, String, String) = ("x · right", "y · top", "z · out of screen")

    var body: some View {
        HStack(spacing: Space.md) {
            ForEach(Array([names.0, names.1, names.2].enumerated()), id: \.offset) { i, name in
                HStack(spacing: 4) {
                    Capsule().fill(AxisGraph.colors[i]).frame(width: 12, height: 3)
                    Text(name).font(.caption2).foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }
}

/// Wrapping row of small chips.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(Brand.textPrimary)
                    .background(Brand.fieldFill, in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, arrange(subviews, width: bounds.width).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}

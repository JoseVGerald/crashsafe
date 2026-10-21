import SwiftUI

/// Weather where you are + how to drive in it.
struct ConditionsCard: View {
    let placeName: String?
    let weather: WeatherSnapshot?
    let isNight: Bool
    let advice: DrivingAdvice
    let isLoading: Bool
    let locationDenied: Bool
    let demoTitle: String?
    var onEnableLocation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(demoTitle ?? placeName ?? (locationDenied ? "Location off" : "Locating…"),
                          systemImage: demoTitle == nil ? "location.fill" : "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                    if let weather {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(Int(weather.temperatureF.rounded()))°")
                                .font(.system(size: 44, weight: .semibold, design: .rounded))
                                .foregroundStyle(Brand.textPrimary)
                                .contentTransition(.numericText())
                            Text(weather.condition.label)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(Brand.textPrimary)
                        }
                    } else if isLoading {
                        Text("Checking the weather…")
                            .font(.title3)
                            .foregroundStyle(Brand.textSecondary)
                            .redacted(reason: .placeholder)
                    } else {
                        Text(locationDenied ? "Turn on location for live conditions" : "Conditions unavailable")
                            .font(.headline)
                            .foregroundStyle(Brand.textPrimary)
                    }
                }
                Spacer()
                if let weather {
                    Image(systemName: weather.condition.systemImage(isDay: weather.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 46))
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if locationDenied && weather == nil {
                Button("Turn on location", action: onEnableLocation)
                    .buttonStyle(.secondary)
            } else {
                Divider().overlay(Brand.stroke)
                HStack(spacing: 8) {
                    Text(advice.headline)
                        .font(.headline)
                        .foregroundStyle(Brand.textPrimary)
                    Spacer()
                    if isNight { StatusChip(text: "Night", systemImage: "moon.fill", tint: Brand.blueInk) }
                    if let wind = weather?.windMph, wind >= 15 {
                        StatusChip(text: "\(Int(wind)) mph", systemImage: "wind", tint: Brand.amberInk)
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 12) {
                    ForEach(advice.tips) { tip in
                        Label {
                            Text(tip.text)
                                .font(.subheadline)
                                .foregroundStyle(Brand.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: tip.systemImage)
                                .foregroundStyle(Brand.blueInk)
                        }
                    }
                }
            }
        }
        .card(padding: Space.md + 4)
        .animation(.spring(response: 0.4), value: weather)
    }
}

/// Live speed vs. what's safe right now.
struct DrivingComparisonCard: View {
    let snapshot: DrivingSnapshot
    let comparison: DrivingComparison
    let isDriving: Bool
    let scenario: DriveScenario?
    var onDemo: (DriveScenario) -> Void
    var onStopDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("You vs. conditions")
                    .font(.headline)
                    .foregroundStyle(Brand.textPrimary)
                Spacer()
                StatusChip(text: comparison.status.label, systemImage: statusIcon, tint: statusTint)
                    .contentTransition(.opacity)
            }

            if isDriving {
                HStack(spacing: Space.lg) {
                    SpeedGauge(speed: snapshot.speedMPH, recommended: comparison.recommendedMaxMPH,
                               limit: snapshot.speedLimitMPH, tint: statusTint)
                        .frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(comparison.message)
                            .font(.subheadline)
                            .foregroundStyle(Brand.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Space.md) {
                            stat("\(Int(snapshot.averageSpeedMPH))", "avg mph")
                            stat("\(snapshot.hardBrakes)", "hard brakes")
                            stat(String(format: "%.1f", snapshot.peakG), "peak g")
                        }
                    }
                }
                if scenario != nil {
                    Button("Stop demo drive", systemImage: "stop.fill", action: onStopDemo)
                        .buttonStyle(.pill(.secondary, height: 44))
                }
            } else {
                Text(comparison.message)
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                Menu {
                    ForEach(DriveScenario.allCases) { scenario in
                        Button(scenario.title, systemImage: scenario.systemImage) { onDemo(scenario) }
                    }
                } label: {
                    Label("Try a demo drive", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(Brand.blueInk)
                        .background(Brand.blueInk.opacity(0.08), in: Capsule())
                }
            }
        }
        .card(padding: Space.md + 4)
        .animation(.spring(response: 0.4), value: isDriving)
        .animation(.easeOut, value: comparison.status)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(Brand.textPrimary)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Brand.textSecondary)
        }
    }

    private var statusTint: Color {
        switch comparison.status {
        case .noData: Brand.textSecondary
        case .onTrack: Brand.greenInk
        case .caution: Brand.amberInk
        case .tooFast: Brand.redInk
        }
    }

    private var statusIcon: String {
        switch comparison.status {
        case .noData: "pause.circle.fill"
        case .onTrack: "checkmark.circle.fill"
        case .caution: "exclamationmark.circle.fill"
        case .tooFast: "exclamationmark.triangle.fill"
        }
    }
}

/// Circular speedometer with a tick at the recommended max.
struct SpeedGauge: View {
    let speed: Double
    let recommended: Double?
    let limit: Double?
    let tint: Color

    private let sweep = 0.75
    private var scaleMax: Double { max(80, ((limit ?? 60) * 1.3 / 10).rounded(.up) * 10) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Brand.fieldFill, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: sweep * min(speed / scaleMax, 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.spring(response: 0.6), value: speed)
            if let recommended {
                Capsule()
                    .fill(Brand.textPrimary)
                    .frame(width: 3, height: 18)
                    .offset(y: -55)
                    .rotationEffect(.degrees(-135 + 270 * min(recommended / scaleMax, 1)))
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                Text("\(Int(speed))")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.default, value: Int(speed))
                Text("mph").font(.caption.weight(.semibold)).foregroundStyle(Brand.textSecondary)
                if let recommended {
                    Text("aim ≤ \(Int(recommended))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.textSecondary)
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(speed)) miles per hour" + (recommended.map { ", recommended \(Int($0)) or less" } ?? ""))
    }
}

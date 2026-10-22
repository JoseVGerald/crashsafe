import SwiftUI

/// How to drive right now and why — no temperature or forecast, nothing to read while driving.
struct RoadAlertCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let advice: DrivingAdvice
    let isNight: Bool
    let isLoading: Bool
    /// Wind gusts worth a chip, if any.
    let windMph: Double?
    let demoTitle: String?
    let showsAttribution: Bool
    var source: WeatherSource? = nil
    var appleLegalURL: URL? = nil
    var appleMarkURL: URL? = nil

    private var isCaution: Bool { advice.speedFactor < 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isCaution ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(isCaution ? Brand.amberInk : Brand.greenInk)
                    .frame(width: 44, height: 44)
                    .background((isCaution ? Brand.amberInk : Brand.greenInk).opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    AdaptiveStack(spacing: 8, verticalAlignment: .firstTextBaseline) {
                        Text(advice.headline)
                            .font(.headline)
                            .foregroundStyle(Brand.textPrimary)
                        Spacer(minLength: 0)
                        if isNight { StatusChip(text: "Night", systemImage: "moon.fill", tint: Brand.blueInk) }
                        if let windMph, windMph >= 15 {
                            StatusChip(text: "\(Int(windMph)) mph", systemImage: "wind", tint: Brand.amberInk)
                        }
                    }
                    Text(isLoading ? "Checking the road conditions near you…" : advice.reason)
                        .font(.subheadline)
                        .foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if let demoTitle {
                        Label(demoTitle, systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.blueInk)
                    }
                }
            }

            Divider().overlay(Brand.stroke)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading),
                                     count: typeSize.isAccessibilitySize ? 1 : 2),
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

            if showsAttribution {
                attribution
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .card(padding: Space.md + 4)
        .animation(.spring(response: 0.4), value: advice)
    }

    /// Apple Weather requires its mark and a link to its legal page; Open-Meteo requires credit (CC BY 4.0).
    @ViewBuilder
    private var attribution: some View {
        if source == .appleWeather, let appleLegalURL {
            Link(destination: appleLegalURL) {
                HStack(spacing: 6) {
                    if let appleMarkURL {
                        AsyncImage(url: appleMarkURL) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Text(" Weather").font(.caption2.weight(.semibold))
                        }
                        .frame(height: 12)
                    } else {
                        Text(" Weather").font(.caption2.weight(.semibold))
                    }
                    Text("Legal").font(.caption2).underline()
                }
                .foregroundStyle(Brand.textSecondary)
            }
            .accessibilityLabel("Data from Apple Weather. Legal attribution.")
        } else {
            Link("Conditions data: Open-Meteo", destination: URL(string: "https://open-meteo.com/")!)
                .font(.caption2)
                .foregroundStyle(Brand.textSecondary)
        }
    }
}

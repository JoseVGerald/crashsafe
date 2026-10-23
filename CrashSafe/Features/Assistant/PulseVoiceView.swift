import AVFoundation
import SwiftData
import SwiftUI

/// Dedicated native tab for Pulse Voice: hands-free conversational assistant for
/// crash response, roadside assistance, and driving coaching.
struct PulseVoiceView: View {
    let user: AuthUser
    @Bindable var viewModel: PulseCallViewModel
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL

    @Query private var profiles: [Profile]
    @Query private var trips: [Trip]

    @State private var micPermissionState: AVAudioSession.RecordPermission = AVAudioSession.sharedInstance().recordPermission

    private let voiceScenarios = [
        ("car.side.fill", "Crash Checklist", "What should I do right after an accident?", Brand.redInk),
        ("truck.box.fill", "Towing & Roadside", "Help me find a nearby tow truck and check rates.", Brand.blueInk),
        ("doc.text.fill", "Insurance & Evidence", "What photos and driver details do I need?", Brand.greenInk),
        ("steeringwheel", "Driving Coaching", "Review my recent driving habits and weather conditions.", Brand.amberInk)
    ]

    var body: some View {
        Group {
            if viewModel.inCall {
                PulseCallScreen(viewModel: viewModel)
                    .transition(.opacity)
            } else {
                idleHub
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.inCall)
        .onAppear {
            updateContext()
            viewModel.prepare()
            micPermissionState = AVAudioSession.sharedInstance().recordPermission
        }
        .onChange(of: profiles.first) { updateContext() }
        .onChange(of: trips.first) { updateContext() }
    }

    private func updateContext() {
        viewModel.contextProvider = { [user, env, profiles, trips] in
            AssistantContext.make(
                user: user,
                profile: profiles.first,
                activeTrip: trips.first(where: \.isActive),
                isOnline: env.connectivity.isOnline,
                activity: env.intelligence.assistantActivity
            )
        }
    }

    // MARK: - Idle Hub View

    private var idleHub: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.lg) {
                    statusBar
                        .padding(.top, Space.xs)

                    heroOrbSection

                    if micPermissionState != .granted {
                        micPermissionBanner
                    }

                    topicStartersSection

                    systemInfoSection

                    alternateActionsSection
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(BrandBackground())
            .navigationTitle("Pulse Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        env.router.selectedTab = .assistant
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: Space.sm) {
            Label(env.connectivity.isOnline ? "Online" : "Offline Mode",
                  systemImage: env.connectivity.isOnline ? "wifi" : "wifi.slash")
                .font(.caption2.weight(.medium))
                .foregroundStyle(env.connectivity.isOnline ? Brand.greenInk : Brand.amberInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (env.connectivity.isOnline ? Brand.greenInk : Brand.amberInk).opacity(0.12),
                    in: Capsule()
                )

            Label(PulseKeys.cartesia() != nil ? "Corey Voice" : "Apple Speech",
                  systemImage: "waveform")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Brand.blueInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Brand.blueInk.opacity(0.12), in: Capsule())

            Spacer()

            if case .failed(let message) = viewModel.phase {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Brand.redInk)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Hero Orb Section

    private var heroOrbSection: some View {
        VStack(spacing: Space.md) {
            Button {
                viewModel.startCall()
            } label: {
                ZStack {
                    Circle()
                        .fill(Brand.surface)
                        .frame(width: 160, height: 160)
                        .overlay(Circle().strokeBorder(Brand.stroke, lineWidth: 1.5))
                        .shadow(color: Brand.blue.opacity(0.15), radius: 18, x: 0, y: 8)

                    PulseVoiceFace(mood: .idle, diameter: 124, badge: "waveform")
                }
                .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.inCall)
            .accessibilityLabel("Start Pulse Voice Call")
            .accessibilityHint("Starts a hands-free conversation with Pulse.")

            VStack(spacing: 6) {
                Text("Pulse Voice Assistant")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Brand.textPrimary)

                Text("Tap the orb or the button below to start a hands-free voice call. Pulse listens when you speak and answers out loud.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Space.sm)
            }

            Button {
                viewModel.startCall()
            } label: {
                Label("Start Voice Call", systemImage: "phone.fill")
            }
            .buttonStyle(.primary)
            .padding(.top, Space.xs)
        }
        .padding(.vertical, Space.md)
    }

    // MARK: - Microphone Permission Banner

    @ViewBuilder
    private var micPermissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.title3)
                .foregroundStyle(Brand.amberInk)

            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone Access")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.textPrimary)
                Text(micPermissionState == .denied
                     ? "Enable microphone in Settings to speak with Pulse."
                     : "Pulse needs microphone access to hear your voice.")
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
            }

            Spacer()

            Button(micPermissionState == .denied ? "Settings" : "Allow") {
                if micPermissionState == .denied {
                    PermissionCenter.openSettings()
                } else {
                    Task {
                        _ = await AVAudioApplication.requestRecordPermission()
                        micPermissionState = AVAudioSession.sharedInstance().recordPermission
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .tint(Brand.blueInk)
        }
        .card(padding: Space.md)
    }

    // MARK: - Quick Topic Starters

    private var topicStartersSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Suggested Topics")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.textSecondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(spacing: Space.sm) {
                ForEach(voiceScenarios, id: \.1) { item in
                    let (icon, title, prompt, tint) = item
                    Button {
                        viewModel.startCall(initialTopic: title)
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(tint.opacity(0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(tint)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Brand.textPrimary)
                                Text(prompt)
                                    .font(.caption)
                                    .foregroundStyle(Brand.textSecondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Brand.textSecondary)
                        }
                        .card(padding: Space.md)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - System Info

    private var systemInfoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(Brand.blueInk)
                Text("How Pulse Voice Works")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.textSecondary)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                infoRow(icon: "waveform.badge.mic", title: "Natural Conversational Turns",
                        description: "Speak freely. Pulse pauses when you finish, thinks, and replies aloud in real-time.")
                Divider().overlay(Brand.stroke)
                infoRow(icon: "shield.lefthalf.filled", title: "Safety & Privacy Guardrails",
                        description: "Deterministic sentence verification ensures safety compliance. Telemetry stays on your device.")
                Divider().overlay(Brand.stroke)
                infoRow(icon: "hand.tap.fill", title: "Interrupt Anytime",
                        description: "Tap the animated orb at any point while Pulse is speaking to immediately cut in.")
            }
            .card(padding: Space.md)
        }
    }

    private func infoRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Brand.blueInk)
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Brand.textPrimary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(Brand.textSecondary)
            }
        }
    }

    // MARK: - Alternate Actions

    private var alternateActionsSection: some View {
        HStack(spacing: Space.md) {
            Button {
                env.router.selectedTab = .assistant
            } label: {
                Label("Open Text Chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.pill(.secondary, height: 46))

            Button {
                if let url = URL(string: "tel://911") { openURL(url) }
            } label: {
                Label("Call 911", systemImage: "phone.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.pill(.danger, height: 46))
        }
    }
}

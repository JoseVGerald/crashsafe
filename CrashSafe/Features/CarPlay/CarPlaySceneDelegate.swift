import CarPlay
import Foundation

/// Bridges the running app's services to the CarPlay scene (one shared environment per process).
enum SharedEnvironment {
    nonisolated(unsafe) static var current: AppEnvironment?
}

/// Native CarPlay UI for the "Driving Task" category.
///
/// CarPlay apps can only use Apple's templates, so this shows an information screen
/// (speed, safe speed, conditions, Pulse's advice) and raises an alert when coaching turns into a warning.
/// Runs in Xcode's CarPlay Simulator with the development entitlement; a real car / App Store needs
/// Apple to approve the CarPlay Driving Task entitlement (see README → CarPlay).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var refresh: Task<Void, Never>?
    private var shownAlertID = 0

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(makeDashboard(), animated: false, completion: nil)
        refresh = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.update()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        refresh?.cancel()
        refresh = nil
        self.interfaceController = nil
    }

    // MARK: Templates

    func makeDashboard() -> CPInformationTemplate {
        CPInformationTemplate(title: "CrashSafe", layout: .twoColumn, items: items(), actions: actions())
    }

    private func items() -> [CPInformationItem] {
        guard let env = SharedEnvironment.current else {
            return [CPInformationItem(title: "Open CrashSafe on your iPhone", detail: "to start coaching")]
        }
        let snapshot = env.driving.snapshot
        let isNight = env.coach.isNight
        let advice = DrivingAdvice.make(weather: env.conditions.weather, isNight: isNight)
        let comparison = DrivingComparison.make(snapshot: snapshot, advice: advice, isDriving: env.driving.isActive)
        var items = [
            CPInformationItem(title: "Speed", detail: "\(Int(snapshot.speedMPH)) mph"),
            CPInformationItem(title: "Safe now", detail: comparison.recommendedMaxMPH.map { "\(Int($0)) mph" } ?? "—"),
            CPInformationItem(title: "Status", detail: comparison.status.label),
        ]
        if let weather = env.conditions.weather {
            items.append(CPInformationItem(title: "Conditions",
                                           detail: "\(Int(weather.temperatureF))° \(weather.condition.label)\(isNight ? " · night" : "")"))
        }
        if let message = env.coach.message {
            items.append(CPInformationItem(title: "Pulse", detail: message.title))
        }
        return items
    }

    private func actions() -> [CPTextButton] {
        let mute = CPTextButton(title: SharedEnvironment.current?.coach.speaks == false ? "Unmute Pulse" : "Mute Pulse",
                                textStyle: .normal) { _ in
            Task { @MainActor in
                guard let coach = SharedEnvironment.current?.coach else { return }
                coach.speaks.toggle()
            }
        }
        let help = CPTextButton(title: "I need help", textStyle: .cancel) { _ in
            Task { @MainActor in SharedEnvironment.current?.crashDetector.simulateCrash() }
        }
        return [mute, help]
    }

    // MARK: Updates

    private func update() {
        guard let template = interfaceController?.rootTemplate as? CPInformationTemplate else { return }
        template.items = items()
        template.actions = actions()
        showWarningIfNeeded()
    }

    /// A full-screen CarPlay alert when Pulse issues a new warning (glanceable, auto-dismisses).
    private func showWarningIfNeeded() {
        guard let coach = SharedEnvironment.current?.coach, let message = coach.message,
              message.severity == .warning, coach.messageID != shownAlertID,
              interfaceController?.presentedTemplate == nil else { return }
        shownAlertID = coach.messageID
        let alert = CPAlertTemplate(titleVariants: [message.title], actions: [
            CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            },
        ])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.interfaceController?.presentedTemplate === alert {
                self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
        }
    }
}

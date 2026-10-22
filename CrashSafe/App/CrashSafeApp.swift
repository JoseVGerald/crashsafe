import SwiftData
import SwiftUI
import UserNotifications

@main
struct CrashSafeApp: App {
    @State private var env: AppEnvironment
    private let container: ModelContainer

    /// Runs on every launch — including when iOS relaunches a closed app in the background for a
    /// location event, where no window (and so no view) ever appears.
    init() {
        let env = AppEnvironment.live()
        let container = AppSchema.makeContainer()
        _env = State(initialValue: env)
        self.container = container
        SharedEnvironment.current = env // read by the CarPlay scene

        // Lock-screen answers ("I'm OK" / "I need help") must reach the app even when it was launched in the background.
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = env.notificationDelegate
        notifications.setNotificationCategories(CrashNotification.categories)

        // The crash check-in reads contacts and saves its outcome straight from the store, not from a view.
        let context = container.mainContext
        env.crashCenter.recipientsProvider = { ownerID in
            let profile = try? context.fetch(FetchDescriptor<Profile>(predicate: #Predicate { $0.ownerID == ownerID })).first
            return profile?.sortedContacts.map { AlertRecipient(name: $0.name, phone: $0.phone) } ?? []
        }
        env.crashCenter.recordOutcome = { ownerID, event, outcome in
            context.insert(CheckInRecord(ownerID: ownerID, outcome: outcome, wasSimulated: event.isSimulated))
            try? context.save()
        }

        env.driveWatcher.resumeIfArmed()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
        }
        .modelContainer(container)
    }
}

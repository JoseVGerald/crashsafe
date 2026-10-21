import SwiftData
import SwiftUI

@main
struct CrashSafeApp: App {
    @State private var env = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
        }
        .modelContainer(for: AppSchema.models)
    }
}

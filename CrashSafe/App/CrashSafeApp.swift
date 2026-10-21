import SwiftData
import SwiftUI

@main
struct CrashSafeApp: App {
    @State private var env = AppEnvironment.live()
    private let container = AppSchema.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
        }
        .modelContainer(container)
    }
}

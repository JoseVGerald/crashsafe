import SwiftData
import SwiftUI

@main
struct CrashSafeApp: App {
    @State private var env: AppEnvironment
    private let container = AppSchema.makeContainer()

    init() {
        let env = AppEnvironment.live()
        _env = State(initialValue: env)
        SharedEnvironment.current = env // read by the CarPlay scene
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
        }
        .modelContainer(container)
    }
}

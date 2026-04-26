import SwiftUI
import SwiftData

@main
struct MobileClawApp: App {
    init() { SmokeTest.runIfRequested() }

    var body: some Scene {
        WindowGroup {
            AppRouter()
        }
        .modelContainer(for: [Conversation.self, StoredMessage.self])
    }
}

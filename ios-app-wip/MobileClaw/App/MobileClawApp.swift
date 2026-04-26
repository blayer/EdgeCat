import SwiftUI
import SwiftData

@main
struct MobileClawApp: App {
    init() { SmokeTest.runIfRequested() }

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .onOpenURL { url in EvalEntryPoint.handle(url) }
        }
        .modelContainer(for: [
            Conversation.self, StoredMessage.self,
            EpisodeEntity.self, RepairRecordEntity.self, DeviceFactEntity.self,
        ])
    }
}

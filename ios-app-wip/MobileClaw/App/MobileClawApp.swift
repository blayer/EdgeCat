import SwiftUI
import SwiftData

@main
struct MobileClawApp: App {
    init() { SmokeTest.runIfRequested() }

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environment(\.theme, MobileClawTheme.shared)
                // Match Android's `darkTheme = true` in MobileClawTheme.kt —
                // the Android app forces dark mode regardless of system
                // preference. iOS mirrors that here so the violet-on-deep-dark
                // palette in AppColors.swift always wins.
                .preferredColorScheme(.dark)
                .onOpenURL { url in EvalEntryPoint.handle(url) }
        }
        .modelContainer(for: [
            Conversation.self, StoredMessage.self,
            EpisodeEntity.self, RepairRecordEntity.self, DeviceFactEntity.self,
        ])
    }
}

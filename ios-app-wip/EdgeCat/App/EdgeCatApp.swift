import SwiftUI
import SwiftData

@main
struct EdgeCatApp: App {
    init() { SmokeTest.runIfRequested() }

    /// Eval-mode launches replace the full app UI with a minimal status
    /// surface. Triggered by `xcrun simctl launch --setenv
    /// EDGECAT_EVAL_MODE=1 …` from the off-device runner. Mirrors
    /// android-app's `EvalActivity` (its own Activity, no LAUNCHER, no
    /// chat UI in the surface). Without the env var, the app boots into
    /// the normal `AppRouter` for end users — no UI regression.
    private static var isEvalMode: Bool {
        ProcessInfo.processInfo.environment["EDGECAT_EVAL_MODE"] == "1"
    }

    @State private var evalStatus = EvalRunStatus.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if Self.isEvalMode && !evalStatus.exited {
                    EvalRunnerView()
                } else {
                    AppRouter()
                }
            }
            .environment(\.theme, EdgeCatTheme.shared)
            // Match Android's `darkTheme = true` in EdgeCatTheme.kt —
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

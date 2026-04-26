import SwiftUI

@main
struct MobileClawApp: App {
    init() { SmokeTest.runIfRequested() }
    var body: some Scene {
        WindowGroup {
            AppRouter()
        }
    }
}

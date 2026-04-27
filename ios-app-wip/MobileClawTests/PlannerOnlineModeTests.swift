import XCTest
@testable import MobileClaw

/// When the device is offline, the planner prompt must include guidance to
/// avoid network-dependent skills. Mirrors android-app's `isOnline` flag.
final class PlannerOnlineModeTests: XCTestCase {

    func testOnlineModeOmitsOfflineNote() {
        let prompt = Planner.buildPlanPrompt(
            userMessage: "fetch wikipedia",
            skills: [],
            isOnline: true)
        XCTAssertFalse(prompt.contains("OFFLINE MODE"))
    }

    func testOfflineModeIncludesGuidance() {
        let prompt = Planner.buildPlanPrompt(
            userMessage: "fetch wikipedia",
            skills: [],
            isOnline: false)
        XCTAssertTrue(prompt.contains("OFFLINE MODE"))
        XCTAssertTrue(prompt.contains("Avoid skills that require"))
    }

    func testOfflineNoteListsInternetSkills() {
        let prompt = Planner.buildPlanPrompt(
            userMessage: "x", skills: [], isOnline: false)
        // Specifically check for the network-skill names so the model
        // knows which ones to avoid by name.
        for name in ConnectivityChecker.internetSkills {
            XCTAssertTrue(prompt.contains(name),
                          "Offline guidance should name '\(name)' so the planner steers clear")
        }
    }
}

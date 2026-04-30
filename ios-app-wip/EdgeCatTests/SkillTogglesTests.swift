import XCTest
@testable import EdgeCat

final class SkillTogglesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SkillToggles.resetAll()
    }

    override func tearDown() {
        SkillToggles.resetAll()
        super.tearDown()
    }

    func testDefaultsToEnabled() {
        XCTAssertTrue(SkillToggles.isEnabled("never-seen-skill"),
                      "Unknown skills should default to enabled (matches Android)")
    }

    func testToggleRoundTrip() {
        SkillToggles.setEnabled(false, for: "calculator")
        XCTAssertFalse(SkillToggles.isEnabled("calculator"))
        SkillToggles.setEnabled(true, for: "calculator")
        XCTAssertTrue(SkillToggles.isEnabled("calculator"))
    }

    func testIndependentSkills() {
        SkillToggles.setEnabled(false, for: "calculator")
        XCTAssertFalse(SkillToggles.isEnabled("calculator"))
        XCTAssertTrue(SkillToggles.isEnabled("clipboard"),
                      "Disabling one skill must not affect others")
    }

    func testSetAllEnabledAppliesToList() {
        SkillToggles.setAllEnabled(false, in: ["calculator", "clipboard", "device-info"])
        XCTAssertFalse(SkillToggles.isEnabled("calculator"))
        XCTAssertFalse(SkillToggles.isEnabled("clipboard"))
        XCTAssertFalse(SkillToggles.isEnabled("device-info"))

        SkillToggles.setAllEnabled(true, in: ["calculator", "clipboard"])
        XCTAssertTrue(SkillToggles.isEnabled("calculator"))
        XCTAssertTrue(SkillToggles.isEnabled("clipboard"))
        XCTAssertFalse(SkillToggles.isEnabled("device-info"),
                       "device-info wasn't in the bulk list — stays as previously set")
    }

    func testResetAllRevertsToDefaults() {
        SkillToggles.setEnabled(false, for: "calculator")
        SkillToggles.resetAll()
        XCTAssertTrue(SkillToggles.isEnabled("calculator"),
                      "After reset, default-enabled wins again")
    }
}

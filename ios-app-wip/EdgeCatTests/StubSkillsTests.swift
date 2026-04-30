import XCTest
@testable import EdgeCat

final class StubSkillsTests: XCTestCase {

    func testDoNotDisturbReturnsNotSupported() async {
        let r = await DoNotDisturbSkill().run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "not_supported_on_ios — DND is user-only")
    }

    func testSetAlarmReturnsNotSupported() async {
        let r = await SetAlarmSkill().run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("not_supported_on_ios") == true)
        XCTAssertTrue(r.error?.contains("set-reminder") == true,
                      "Should hint at the alternative skill so the planner can replan")
    }

    func testListAppsReturnsNotSupported() async {
        let r = await ListAppsSkill().run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "not_supported_on_ios")
    }

    func testStubMetadataConsistent() {
        XCTAssertEqual(DoNotDisturbSkill().name, "do-not-disturb")
        XCTAssertEqual(SetAlarmSkill().name, "set-alarm")
        XCTAssertEqual(ListAppsSkill().name, "list-apps")
        for s in [DoNotDisturbSkill().summary,
                  SetAlarmSkill().summary,
                  ListAppsSkill().summary] {
            XCTAssertEqual(s.tier, "base")
            XCTAssertFalse(s.description.isEmpty)
        }
    }
}

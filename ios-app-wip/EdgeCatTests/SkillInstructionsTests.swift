import XCTest
@testable import EdgeCat

final class SkillInstructionsTests: XCTestCase {

    private let slug = "test-instructions-slug"

    override func setUp() {
        super.setUp()
        SkillInstructions.clear(slug: slug)
    }

    override func tearDown() {
        SkillInstructions.clear(slug: slug)
        super.tearDown()
    }

    func testNoOverrideReturnsNil() {
        XCTAssertNil(SkillInstructions.override(for: slug))
    }

    func testEffectiveFallsBackToDefault() {
        let s = SkillInstructions.effective(slug: slug, default: "default text")
        XCTAssertEqual(s, "default text")
    }

    func testOverrideRoundTrip() {
        SkillInstructions.setOverride("user override", for: slug)
        XCTAssertEqual(SkillInstructions.override(for: slug), "user override")
        XCTAssertEqual(SkillInstructions.effective(slug: slug, default: "default"),
                       "user override")
    }

    func testEmptyOverrideClears() {
        SkillInstructions.setOverride("real override", for: slug)
        SkillInstructions.setOverride("", for: slug)
        XCTAssertNil(SkillInstructions.override(for: slug),
                     "Empty string must delete the override so SKILL.md default wins again")
    }

    func testNilOverrideClears() {
        SkillInstructions.setOverride("real override", for: slug)
        SkillInstructions.setOverride(nil, for: slug)
        XCTAssertNil(SkillInstructions.override(for: slug))
    }

    func testClearByName() {
        SkillInstructions.setOverride("o", for: slug)
        SkillInstructions.clear(slug: slug)
        XCTAssertNil(SkillInstructions.override(for: slug))
    }

    func testIndependenceAcrossSlugs() {
        SkillInstructions.setOverride("o-a", for: slug)
        defer { SkillInstructions.clear(slug: slug) }
        SkillInstructions.setOverride("o-b", for: "other-slug")
        defer { SkillInstructions.clear(slug: "other-slug") }
        XCTAssertEqual(SkillInstructions.override(for: slug), "o-a")
        XCTAssertEqual(SkillInstructions.override(for: "other-slug"), "o-b")
    }
}

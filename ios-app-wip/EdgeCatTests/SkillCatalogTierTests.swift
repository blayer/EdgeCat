import XCTest
@testable import EdgeCat

/// Skill catalog rendering must split base vs deferred skills so the
/// planner prompt isn't bloated with deferred-skill detail and the agent
/// knows it can call `search-skills` to load full instructions on demand.
final class SkillCatalogTierTests: XCTestCase {

    func testBaseSkillsRenderWithFullDescription() {
        let rendered = Planner.renderCatalog([
            SkillSummary(name: "calculator", description: "Compute math.",
                         instructions: "", tier: "base"),
            SkillSummary(name: "calendar", description: "Manage events.",
                         instructions: "", tier: "base"),
        ])
        XCTAssertTrue(rendered.contains("- calculator: Compute math."))
        XCTAssertTrue(rendered.contains("- calendar: Manage events."))
        XCTAssertFalse(rendered.contains("search-skills"),
                       "Search hint omitted when no deferred skills present")
    }

    func testBaseSkillInstructionsRenderOnContinuationLine() {
        let rendered = Planner.renderCatalog([
            SkillSummary(name: "calc", description: "math",
                         instructions: "Pass an `expression` arg.",
                         tier: "base"),
        ])
        XCTAssertTrue(rendered.contains("- calc: math\n  Pass an `expression` arg."),
                      "Instructions should appear indented under the catalog entry, got:\n\(rendered)")
    }

    func testDeferredSkillsAppearAsNameOnlyWithSearchSkillsHint() {
        let rendered = Planner.renderCatalog([
            SkillSummary(name: "calculator", description: "Compute math.",
                         tier: "base"),
            SkillSummary(name: "obscure-deferred",
                         description: "Some on-demand thing",
                         instructions: "lots of detail not shown until loaded",
                         tier: "deferred"),
        ])
        XCTAssertTrue(rendered.contains("calculator"))
        XCTAssertTrue(rendered.contains("obscure-deferred"),
                      "Deferred skill name must appear in the catalog")
        XCTAssertFalse(rendered.contains("lots of detail"),
                       "Deferred skill instructions must NOT be inlined")
        XCTAssertTrue(rendered.contains("search-skills"),
                      "Hint to call search-skills must be present when deferred skills exist")
    }

    func testCatalogWithOnlyDeferredSkillsStillRendersHint() {
        let rendered = Planner.renderCatalog([
            SkillSummary(name: "deferred-a", description: "x", tier: "deferred"),
        ])
        XCTAssertTrue(rendered.contains("search-skills"))
        XCTAssertTrue(rendered.contains("deferred-a"))
    }
}

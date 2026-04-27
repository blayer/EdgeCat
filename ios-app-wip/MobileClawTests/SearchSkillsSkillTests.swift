import XCTest
@testable import MobileClaw

/// `search-skills` returns deferred-tier skills' instructions on demand
/// so the planner can route to them without bloating the catalog. Mirrors
/// android-app/.../OrchestrationBridge.searchSkills.
final class SearchSkillsSkillTests: XCTestCase {

    private let mixed: [SkillSummary] = [
        SkillSummary(name: "calculator", description: "math", instructions: "use expression",
                     tier: "base"),
        SkillSummary(name: "translate", description: "translate text",
                     instructions: "Pass `text` and `targetLang`. Returns the translation.",
                     tier: "deferred"),
        SkillSummary(name: "morse", description: "encode morse code",
                     instructions: "Pass `text`. Returns dots and dashes.",
                     tier: "deferred"),
    ]

    func testReturnsAllDeferredSkillsForEmptyQuery() async {
        let skill = SearchSkillsSkill { self.mixed }
        let result = await skill.run(args: [:])
        XCTAssertTrue(result.success)
        guard let data = result.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Output was not JSON: \(result.output)"); return
        }
        let loaded = obj["loaded"] as? [String] ?? []
        XCTAssertEqual(Set(loaded), ["translate", "morse"])
    }

    func testFiltersByQueryTokens() async {
        let skill = SearchSkillsSkill { self.mixed }
        let result = await skill.run(args: ["query": "translate"])
        guard let data = result.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Bad JSON"); return
        }
        let loaded = obj["loaded"] as? [String] ?? []
        XCTAssertEqual(loaded, ["translate"])
    }

    func testIgnoresBaseSkillsEvenIfQueryMatches() async {
        let skill = SearchSkillsSkill { self.mixed }
        let result = await skill.run(args: ["query": "calculator math"])
        guard let data = result.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Bad JSON"); return
        }
        let loaded = obj["loaded"] as? [String] ?? []
        XCTAssertTrue(loaded.isEmpty,
                      "Base-tier skill should never be returned by search-skills")
    }

    func testReturnsInstructionsTruncatedTo800Chars() async {
        let bigInstructions = String(repeating: "x", count: 2000)
        let summaries = [
            SkillSummary(name: "huge", description: "x",
                         instructions: bigInstructions, tier: "deferred"),
        ]
        let skill = SearchSkillsSkill { summaries }
        let result = await skill.run(args: ["query": "huge"])
        guard let data = result.output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = obj["skills"] as? [[String: Any]],
              let inst = skills.first?["instructions"] as? String else {
            XCTFail("Bad JSON"); return
        }
        XCTAssertEqual(inst.count, 800,
                       "Instructions should be truncated at 800 chars to keep planner prompts bounded")
    }
}

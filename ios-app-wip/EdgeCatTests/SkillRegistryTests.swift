import XCTest
@testable import EdgeCat

private final class FakeSkill: Skill, @unchecked Sendable {
    let name: String
    let description: String
    let _result: ToolExecutionResult
    private(set) var lastArgs: [String: String] = [:]

    init(name: String, description: String = "", result: ToolExecutionResult) {
        self.name = name
        self.description = description
        self._result = result
    }

    func run(args: [String: String]) async -> ToolExecutionResult {
        lastArgs = args
        return _result
    }
}

@MainActor
final class SkillRegistryTests: XCTestCase {

    func testRegisterAndDispatch() async {
        let calc = FakeSkill(name: "calc",
                             result: ToolExecutionResult(success: true, output: "4"))
        let reg = SkillRegistry(skills: [calc])
        let r = await reg.executeTool(toolName: "calc", args: ["expr": "2+2"])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "4")
        XCTAssertEqual(calc.lastArgs, ["expr": "2+2"])
    }

    func testUnknownToolReturnsError() async {
        let reg = SkillRegistry(skills: [])
        let r = await reg.executeTool(toolName: "nope", args: [:])
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("unknown skill") == true)
    }

    func testGetAvailableSkillsSortedByName() {
        let reg = SkillRegistry(skills: [
            FakeSkill(name: "zeta", result: ToolExecutionResult(success: true)),
            FakeSkill(name: "alpha", result: ToolExecutionResult(success: true)),
            FakeSkill(name: "mu", result: ToolExecutionResult(success: true)),
        ])
        let names = reg.getAvailableSkills().map(\.name)
        XCTAssertEqual(names, ["alpha", "mu", "zeta"])
    }

    func testRegisterOverwritesByName() async {
        let reg = SkillRegistry(skills: [
            FakeSkill(name: "x", result: ToolExecutionResult(success: false, error: "old")),
        ])
        // Allow concurrent register barrier to drain.
        try? await Task.sleep(nanoseconds: 20_000_000)
        reg.register(FakeSkill(name: "x", result: ToolExecutionResult(success: true, output: "new")))
        try? await Task.sleep(nanoseconds: 20_000_000)
        let r = await reg.executeTool(toolName: "x", args: [:])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "new")
    }

    func testDefaultSetContainsExpectedSkills() async throws {
        let reg = SkillRegistry.defaultSet()
        // SkillRegistry registers via a barrier dispatch; wait one tick so the
        // catalog is fully populated before we read it back.
        try await Task.sleep(nanoseconds: 50_000_000)
        let names = Set(reg.getAvailableSkills().map(\.name))
        // Calculator was de-registered from defaultSet (PR #44); pure
        // arithmetic is rare and the prior placement caused the
        // planner to mis-route date arithmetic through it. The skill
        // can still be re-loaded on demand via `search-skills` if a
        // task genuinely needs NSExpression evaluation.
        let expected: [String] = [
            "clipboard", "device-info", "fetch-web-content", "search-web",
            "read-contacts", "calendar", "set-reminder", "list-photos", "get-location",
            "phone-call", "send-sms", "flashlight", "share-content", "scan-barcode",
            "query-wikipedia",
            "do-not-disturb", "set-alarm", "list-apps",
        ]
        for n in expected {
            XCTAssertTrue(names.contains(n), "defaultSet missing \(n)")
        }
    }

    /// JS skills are no longer hand-listed; they're auto-loaded from
    /// `Resources/skills/<slug>/SKILL.md`. Verify the scanner picks them up
    /// and they reach the registry. `query-wikipedia` is the canonical
    /// JS-only skill that ships in the iOS bundle.
    func testDefaultSetAutoLoadsJsSkills() async throws {
        SkillToggles.resetAll()
        let reg = SkillRegistry.defaultSet()
        try await Task.sleep(nanoseconds: 50_000_000)
        let names = Set(reg.allSkills().map(\.name))
        XCTAssertTrue(names.contains("query-wikipedia"))
    }

    /// `getAvailableSkills()` must filter by user toggles; `allSkills()`
    /// must not. The planner uses the filtered view; the manager UI uses
    /// the full one. Test fixture is `clipboard` — small, registered,
    /// and side-effect-light; calculator (the original fixture) was
    /// de-registered in PR #44.
    func testTogglesFilterAvailableButNotAll() async throws {
        SkillToggles.resetAll()
        let reg = SkillRegistry.defaultSet()
        try await Task.sleep(nanoseconds: 50_000_000)

        SkillToggles.setEnabled(false, for: "clipboard")
        defer { SkillToggles.resetAll() }

        let visible = Set(reg.getAvailableSkills().map(\.name))
        let everything = Set(reg.allSkills().map(\.name))
        XCTAssertFalse(visible.contains("clipboard"),
                       "Disabled skill should be hidden from the planner")
        XCTAssertTrue(everything.contains("clipboard"),
                      "Manager UI must still see disabled skill")
    }

    func testUpdateSkillInstructionsIsNoOpForBuiltIns() async {
        let reg = SkillRegistry.defaultSet()
        // `clipboard` is a registered native (built-in) skill, so its
        // instructions can't be updated through the manager UI hook —
        // that affordance only applies to JS-bundled custom skills.
        let updated = await reg.updateSkillInstructions(skillName: "clipboard",
                                                        newInstructions: "do thing")
        XCTAssertFalse(updated)
    }
}

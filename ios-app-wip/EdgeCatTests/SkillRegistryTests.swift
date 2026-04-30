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
        let expected: [String] = [
            "calculator", "clipboard", "device-info", "fetch-web-content", "search-web",
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
    /// the full one.
    func testTogglesFilterAvailableButNotAll() async throws {
        SkillToggles.resetAll()
        let reg = SkillRegistry.defaultSet()
        try await Task.sleep(nanoseconds: 50_000_000)

        SkillToggles.setEnabled(false, for: "calculator")
        defer { SkillToggles.resetAll() }

        let visible = Set(reg.getAvailableSkills().map(\.name))
        let everything = Set(reg.allSkills().map(\.name))
        XCTAssertFalse(visible.contains("calculator"),
                       "Disabled skill should be hidden from the planner")
        XCTAssertTrue(everything.contains("calculator"),
                      "Manager UI must still see disabled skill")
    }

    /// `executeTool` should still run a disabled skill if invoked by name —
    /// the toggle gates planner exposure, not direct invocation. This
    /// matches Android's behavior where disabled skills can still be
    /// triggered via direct API once the planner has decided to.
    func testDisabledSkillIsStillExecutable() async throws {
        SkillToggles.resetAll()
        let reg = SkillRegistry.defaultSet()
        try await Task.sleep(nanoseconds: 50_000_000)
        SkillToggles.setEnabled(false, for: "calculator")
        defer { SkillToggles.resetAll() }

        let r = await reg.executeTool(toolName: "calculator",
                                       args: ["expression": "2+2"])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "4")
    }

    func testUpdateSkillInstructionsIsNoOpForBuiltIns() async {
        let reg = SkillRegistry.defaultSet()
        let updated = await reg.updateSkillInstructions(skillName: "calculator",
                                                        newInstructions: "do thing")
        XCTAssertFalse(updated)
    }
}

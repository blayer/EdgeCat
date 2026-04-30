import XCTest
@testable import EdgeCat

final class SkillToolsRoutingTests: XCTestCase {

    func testNativeSkillResolvesToItsOwnSkillName() {
        // On iOS each native skill is its own Skill class registered in
        // SkillRegistry under its skill name (e.g. "calendar"). Android's
        // NATIVE_SKILL_TOOLS values (e.g. "manageCalendar") were AgentTools
        // method names — iOS doesn't need that indirection. resolveTool
        // returns the skill name so the registry lookup succeeds.
        XCTAssertEqual(SkillTools.resolveTool(skillName: "calendar", toolName: nil),
                       "calendar")
        XCTAssertEqual(SkillTools.resolveTool(skillName: "calculator", toolName: nil),
                       "calculator")
    }

    func testUnderscoreSkillNameNormalizesToHyphen() {
        // LLMs often emit underscore-cased names; normalize to hyphen so
        // the registry's hyphen-cased registration succeeds.
        XCTAssertEqual(SkillTools.resolveTool(skillName: "send_sms", toolName: nil),
                       "send-sms")
    }

    func testLlmOnlySkillReturnsNil() {
        XCTAssertNil(SkillTools.resolveTool(skillName: "summarize", toolName: nil))
        XCTAssertNil(SkillTools.resolveTool(skillName: "compose", toolName: nil))
    }

    func testUnknownSkillRoutesToItsOwnSkillName() {
        // JS skills are registered under their slug. An unknown slug
        // gets routed to itself; if no Skill is registered, the registry
        // returns "unknown skill: <name>" which the orchestrator surfaces
        // as a step failure (and the diagnostic-LLM repair can replan).
        XCTAssertEqual(SkillTools.resolveTool(skillName: "wikipedia", toolName: nil),
                       "wikipedia")
    }

    func testExplicitToolNameOverrides() {
        XCTAssertEqual(SkillTools.resolveTool(skillName: "calendar", toolName: "customTool"),
                       "customTool")
    }

    func testEmptySkillAndToolReturnsNil() {
        XCTAssertNil(SkillTools.resolveTool(skillName: nil, toolName: nil))
        XCTAssertNil(SkillTools.resolveTool(skillName: "", toolName: ""))
    }
}

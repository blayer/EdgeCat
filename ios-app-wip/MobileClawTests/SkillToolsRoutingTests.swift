import XCTest
@testable import MobileClaw

final class SkillToolsRoutingTests: XCTestCase {

    func testNativeSkillResolvesToNativeTool() {
        XCTAssertEqual(SkillTools.resolveTool(skillName: "calendar", toolName: nil),
                       "manageCalendar")
        XCTAssertEqual(SkillTools.resolveTool(skillName: "calculator", toolName: nil),
                       "calculate")
    }

    func testUnderscoreSkillNameNormalizesToHyphen() {
        XCTAssertEqual(SkillTools.resolveTool(skillName: "send_sms", toolName: nil),
                       "sendSms")
    }

    func testLlmOnlySkillReturnsNil() {
        XCTAssertNil(SkillTools.resolveTool(skillName: "summarize", toolName: nil))
        XCTAssertNil(SkillTools.resolveTool(skillName: "compose", toolName: nil))
    }

    func testUnknownSkillRoutesToRunJs() {
        XCTAssertEqual(SkillTools.resolveTool(skillName: "wikipedia", toolName: nil),
                       "runJs")
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

import XCTest
@testable import MobileClaw

final class CalculatorSkillTests: XCTestCase {

    func testAddition() async {
        let r = await CalculatorSkill().run(args: ["expression": "2 + 3"])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "5")
    }

    func testParensAndPrecedence() async {
        let r = await CalculatorSkill().run(args: ["expression": "3 * (4 + 5)"])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "27")
    }

    func testUnicodeOperators() async {
        let m = await CalculatorSkill().run(args: ["expression": "6 × 7"])
        XCTAssertTrue(m.success)
        XCTAssertEqual(m.output, "42")
        let d = await CalculatorSkill().run(args: ["expression": "20 ÷ 4"])
        XCTAssertTrue(d.success)
        XCTAssertEqual(d.output, "5")
    }

    func testExprAlias() async {
        let r = await CalculatorSkill().run(args: ["expr": "10 - 3"])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "7")
    }

    func testMissingExpression() async {
        let r = await CalculatorSkill().run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertNotNil(r.error)
        XCTAssertTrue(r.error?.contains("missing") == true)
    }

    func testInvalidExpression() async {
        let r = await CalculatorSkill().run(args: ["expression": "this is not math"])
        XCTAssertFalse(r.success)
    }

    func testSkillMetadata() {
        let s = CalculatorSkill()
        XCTAssertEqual(s.name, "calculator")
        XCTAssertFalse(s.description.isEmpty)
        XCTAssertEqual(s.tier, "base")
        XCTAssertEqual(s.summary.name, "calculator")
    }
}

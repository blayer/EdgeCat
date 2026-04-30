import XCTest
@testable import EdgeCat

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

    func testRejectsProseWithStrayNumber() async {
        // Planner mistakenly piped a synthesis description into the
        // calculator. The cleanExpression heuristic should reject prose
        // (≤70% arithmetic chars) instead of extracting "-8" or similar
        // and silently returning a meaningless result.
        let r = await CalculatorSkill().run(args: [
            "expression":
                "Synthesize the information gathered from the web search to draft a potential itinerary 8 hours",
        ])
        XCTAssertFalse(r.success,
                       "Free-form prose with a stray number must not silently evaluate")
    }

    func testRejectsDateShapeInput() async {
        // Planner sometimes pipes a raw yyyy-MM-dd date into the
        // calculator (e.g. when the user asks "show me a photo from
        // this week"). NSExpression(format:) would happily parse this
        // as 2026-04-29 = 1993, but more often raises an uncatchable
        // Obj-C exception that hangs the step. Reject up front.
        let r = await CalculatorSkill().run(args: ["expression": "2026-04-29"])
        XCTAssertFalse(r.success,
                       "Date-shape input must be rejected before NSExpression sees it")
        XCTAssertTrue(r.error?.contains("not a calculator expression") == true)
    }

    func testRejectsTrailingOperator() async {
        let r = await CalculatorSkill().run(args: ["expression": "3 +"])
        XCTAssertFalse(r.success)
    }

    func testRejectsTwoAdjacentNumbers() async {
        // "2026 04" — NSExpression can't decide whether this is one
        // number or two. Reject.
        let r = await CalculatorSkill().run(args: ["expression": "2026 04"])
        XCTAssertFalse(r.success)
    }

    func testAcceptsArithmeticWithCurrencySymbols() async {
        // Mostly-arithmetic input with a few stray non-arith chars
        // (currency signs) should still evaluate after cleaning.
        let r = await CalculatorSkill().run(args: ["expression": "$3.50 + $1.25"])
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "4.75")
    }

    func testSkillMetadata() {
        let s = CalculatorSkill()
        XCTAssertEqual(s.name, "calculator")
        XCTAssertFalse(s.description.isEmpty)
        XCTAssertEqual(s.tier, "base")
        XCTAssertEqual(s.summary.name, "calculator")
    }
}

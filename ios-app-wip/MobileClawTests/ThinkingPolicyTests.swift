import XCTest
@testable import MobileClaw

final class ThinkingPolicyTests: XCTestCase {

    func testFromIntFallback() {
        XCTAssertEqual(ThinkingMode.from(0), .auto)
        XCTAssertEqual(ThinkingMode.from(1), .off)
        XCTAssertEqual(ThinkingMode.from(2), .aggressive)
        XCTAssertEqual(ThinkingMode.from(99), .auto)
        XCTAssertEqual(ThinkingMode.from(-1), .auto)
    }

    func testOffModeAlwaysFalse() {
        let p = ThinkingPolicy(mode: .off)
        XCTAssertFalse(p.planner(userMessage: "explain quantum mechanics in detail", iteration: 0))
        XCTAssertFalse(p.replan(replanAttempt: 5))
        XCTAssertFalse(p.evaluator())
        XCTAssertFalse(p.format(complexOutput: true))
        XCTAssertFalse(p.llmStep())
        XCTAssertFalse(p.saveAsSkill())
    }

    func testAggressiveModeAlwaysTrueExceptEvaluatorAndStep() {
        let p = ThinkingPolicy(mode: .aggressive)
        XCTAssertTrue(p.planner(userMessage: "hi", iteration: 0))
        XCTAssertTrue(p.planner(userMessage: "anything", iteration: 5))
        XCTAssertTrue(p.replan(replanAttempt: 0))
        XCTAssertFalse(p.evaluator(), "Evaluator stays off in all modes — small models flip on CoT")
        XCTAssertTrue(p.format(complexOutput: false))
        XCTAssertFalse(p.llmStep(), "Per-step LLM is pure synthesis; thinking off")
        XCTAssertTrue(p.saveAsSkill())
    }

    func testAutoMode() {
        let p = ThinkingPolicy(mode: .auto)
        XCTAssertTrue(p.planner(userMessage: "Build a rich nuanced research plan", iteration: 0))
        XCTAssertFalse(p.planner(userMessage: "what time is it", iteration: 0),
                       "Simple-prefix request → no thinking even on planner-first")
        XCTAssertFalse(p.planner(userMessage: "longer request that triggers thinking", iteration: 1),
                       "iter > 0 → no thinking unless aggressive")
        XCTAssertTrue(p.replan(replanAttempt: 2))
        XCTAssertFalse(p.replan(replanAttempt: 1))
        XCTAssertTrue(p.format(complexOutput: true))
        XCTAssertFalse(p.format(complexOutput: false))
        XCTAssertFalse(p.saveAsSkill())
    }

    func testAutoTrivialRequestFastPath() {
        let p = ThinkingPolicy(mode: .auto)
        // <= 4 words is treated as trivial regardless of prefix
        XCTAssertFalse(p.planner(userMessage: "tell me a joke", iteration: 0))
        XCTAssertFalse(p.planner(userMessage: "ok", iteration: 0))
        // simple-prefix patterns are also bypassed
        XCTAssertFalse(p.planner(userMessage: "set a timer for ten minutes", iteration: 0))
        XCTAssertFalse(p.planner(userMessage: "call my mom please right now", iteration: 0))
    }
}

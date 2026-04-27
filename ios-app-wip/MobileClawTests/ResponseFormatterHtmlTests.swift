import XCTest
@testable import MobileClaw

final class ResponseFormatterHtmlTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        let canned: String
        init(canned: String = "synthesized") { self.canned = canned }
        func generateResponse(prompt: String, enableThinking: Bool) async throws -> String { canned }
        func cancel() {}
    }

    private func makePlan(stepCount: Int = 1) -> ExecutionPlan {
        ExecutionPlan(goal: "g", reasoning: "r",
                      steps: (1...stepCount).map { i in
                          PlanStep(id: "s\(i)", description: "d\(i)", skillName: "x")
                      })
    }

    func testSingleStepWithPlainOutputPassesThrough() async throws {
        let f = ResponseFormatter(llm: StubLLM(canned: "should-not-be-used"),
                                   policy: ThinkingPolicy(mode: .off))
        let result = try await f.format(
            userMessage: "x",
            plan: makePlan(),
            results: ["s1": StepResult(stepId: "s1", status: .completed,
                                       output: "the answer is 42")])
        XCTAssertEqual(result.text, "the answer is 42")
        XCTAssertFalse(result.isHtml)
    }

    func testMultipleStepsTriggerLlmSynthesis() async throws {
        let llm = StubLLM(canned: "combined answer")
        let f = ResponseFormatter(llm: llm, policy: ThinkingPolicy(mode: .off))
        let result = try await f.format(
            userMessage: "x",
            plan: makePlan(stepCount: 3),
            results: [
                "s1": StepResult(stepId: "s1", status: .completed, output: "a"),
                "s2": StepResult(stepId: "s2", status: .completed, output: "b"),
                "s3": StepResult(stepId: "s3", status: .completed, output: "c"),
            ])
        XCTAssertEqual(result.text, "combined answer")
        XCTAssertFalse(result.isHtml)
    }

    func testHtmlMarkupSetsHtmlFlag() async throws {
        let f = ResponseFormatter(llm: StubLLM(canned: "x"),
                                   policy: ThinkingPolicy(mode: .off))
        let result = try await f.format(
            userMessage: "show me a table",
            plan: makePlan(),
            results: ["s1": StepResult(stepId: "s1", status: .completed,
                                       output: "<table><tr><td>1</td></tr></table>")])
        XCTAssertTrue(result.isHtml,
                      "Output containing <table> must set isHtml=true")
    }

    func testNoHtmlMarkupKeepsHtmlFlagFalse() async throws {
        let f = ResponseFormatter(llm: StubLLM(canned: "x"),
                                   policy: ThinkingPolicy(mode: .off))
        let result = try await f.format(
            userMessage: "x",
            plan: makePlan(),
            results: ["s1": StepResult(stepId: "s1", status: .completed,
                                       output: "1 < 2 is true")])
        XCTAssertFalse(result.isHtml,
                       "Bare < in prose must not trigger HTML flag")
    }

    func testHtmlDetectionRecognizesCommonTags() {
        for marker in ["<table>", "<ul>", "<ol>", "<pre>", "<code>",
                       "<a href=\"x\">", "<div class=\"y\">", "<h1>", "<img>"] {
            XCTAssertTrue(ResponseFormatter.containsHtmlMarkup(marker),
                          "Should recognize \(marker)")
        }
    }
}

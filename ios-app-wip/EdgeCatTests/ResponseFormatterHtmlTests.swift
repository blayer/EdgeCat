import XCTest
@testable import EdgeCat

final class ResponseFormatterHtmlTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        let canned: String
        var prompts: [String] = []
        init(canned: String = "<msg>synthesized</msg>") { self.canned = canned }
        func generateResponse(prompt: String, enableThinking: Bool, maxOutputTokens: Int) async throws -> String {
            prompts.append(prompt)
            return canned
        }
        func cancel() {}
    }

    private func makePlan(stepCount: Int = 1) -> ExecutionPlan {
        ExecutionPlan(goal: "g", reasoning: "r",
                      steps: (1...stepCount).map { i in
                          PlanStep(id: "s\(i)", description: "d\(i)", skillName: "x")
                      })
    }

    func testSingleScalarOutputPassesThroughWithoutLlm() async throws {
        let llm = StubLLM(canned: "should-not-be-used")
        let f = ResponseFormatter(llm: llm, policy: ThinkingPolicy(mode: .off))
        let result = try await f.format(
            userMessage: "x",
            plan: makePlan(),
            results: ["s1": StepResult(stepId: "s1", status: .completed,
                                       output: "the answer is 42")])
        XCTAssertEqual(result.text, "the answer is 42")
        XCTAssertFalse(result.isHtml)
        XCTAssertTrue(llm.prompts.isEmpty,
                      "Trivial scalar must skip the formatter LLM")
    }

    func testMultipleStepsTriggerLlmSynthesis() async throws {
        let llm = StubLLM(canned: "<msg>combined answer</msg>")
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
        let f = ResponseFormatter(llm: StubLLM(),
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
        let f = ResponseFormatter(llm: StubLLM(),
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

    // MARK: - Android-parity: JSON envelopes go through the LLM

    func testSearchWebJsonEnvelopeRoutesThroughLlm() async throws {
        // Real search-web shape: status + result_count + query + multi-line
        // results blob. The LLM-bypass shortcut would dump this raw JSON.
        let json = #"{"status":"succeeded","result_count":2,"query":"weather Tokyo","results":"1. Tokyo Forecast\n   https://example.com\n   Sunny, 22C"}"#
        let llm = StubLLM(canned: "<msg>Tokyo: sunny, 22°C. Source: example.com</msg>")
        let f = ResponseFormatter(llm: llm, policy: ThinkingPolicy(mode: .off))
        let result = try await f.format(
            userMessage: "weather in Tokyo",
            plan: makePlan(),
            results: ["s1": StepResult(stepId: "s1", status: .completed, output: json)])
        XCTAssertEqual(result.text, "Tokyo: sunny, 22°C. Source: example.com")
        XCTAssertFalse(result.isHtml)
        XCTAssertEqual(llm.prompts.count, 1,
                       "JSON envelope must invoke the formatter LLM")
        XCTAssertTrue(llm.prompts[0].contains("status: succeeded"),
                      "Prompt should include the preprocessed YAML-ish form")
        XCTAssertFalse(llm.prompts[0].contains(#""status":"succeeded""#),
                       "Prompt should not pass through raw JSON")
    }

    func testTrivialScalarInsideJsonStillSkipsLlm() throws {
        // Skill output: {"status":"succeeded","result":"42"} → drop status,
        // single scalar `result` → return "42" with no LLM call.
        let json = #"{"status":"succeeded","result":"42"}"#
        XCTAssertEqual(ResponseFormatter.tryTrivialRender(json), "42")
    }

    func testListOfScalarsInsideJsonRendersAsBullets() throws {
        let json = #"{"status":"succeeded","items":["alpha","beta","gamma"]}"#
        XCTAssertEqual(ResponseFormatter.tryTrivialRender(json),
                       "• alpha\n• beta\n• gamma")
    }

    func testPreprocessJsonEnvelopeYieldsIndentedYaml() {
        let json = #"{"status":"succeeded","query":"weather"}"#
        let pp = ResponseFormatter.preprocess(json)
        XCTAssertTrue(pp.contains("status: succeeded"))
        XCTAssertTrue(pp.contains("query: weather"))
        XCTAssertFalse(pp.contains("{"), "JSON braces must be stripped")
    }

    func testExtractMessageStripsWrapperAndPreamble() {
        // "Sure!" outside, "Here's…" inside — both stripped per Android.
        let raw = "Sure! <msg>Here's the result: 42 degrees.</msg>"
        XCTAssertEqual(ResponseFormatter.extractMessage(raw), "42 degrees.")
    }

    func testExtractMessageHandlesUnclosedTag() {
        // LLM cut off mid-stream — recover the body up to EOS.
        let raw = "<msg>Partial answer that"
        XCTAssertEqual(ResponseFormatter.extractMessage(raw),
                       "Partial answer that")
    }
}

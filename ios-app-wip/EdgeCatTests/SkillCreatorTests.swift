import XCTest
@testable import EdgeCat

/// Diagnostic-LLM repair + SkillCreator prompt builders. Mirrors
/// android-app/.../SkillCreator.kt's prompt + parse cases.
final class SkillCreatorTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        var canned: String
        init(_ canned: String) { self.canned = canned }
        func generateResponse(prompt: String, enableThinking: Bool) async throws -> String { canned }
        func cancel() {}
    }

    // MARK: - parseDiagnostic

    func testParsesValidDiagnosticJson() {
        let raw = #"""
        ```json
        {
          "diagnosis": "Date format is wrong",
          "fixType": "retry_with_different_args",
          "alternativeSkillName": null,
          "alternativeArgs": {"startTime": "2026-04-28T09:00"},
          "updatedInstructions": null
        }
        ```
        """#
        let result = SkillCreator.parseDiagnostic(raw)
        XCTAssertEqual(result.diagnosis, "Date format is wrong")
        XCTAssertEqual(result.fixType, "retry_with_different_args")
        XCTAssertNil(result.alternativeSkillName)
        XCTAssertEqual(result.alternativeArgs["startTime"], "2026-04-28T09:00")
    }

    func testParseHandlesAlternativeSkillName() {
        let raw = #"""
        {"diagnosis":"no clock","fixType":"use_alternative_skill","alternativeSkillName":"timer","alternativeArgs":{},"updatedInstructions":null}
        """#
        let result = SkillCreator.parseDiagnostic(raw)
        XCTAssertEqual(result.fixType, "use_alternative_skill")
        XCTAssertEqual(result.alternativeSkillName, "timer")
    }

    func testParseFallsBackToUnfixableOnGarbage() {
        let result = SkillCreator.parseDiagnostic("the model just talked about its feelings")
        XCTAssertEqual(result.fixType, "unfixable")
        XCTAssertTrue(result.diagnosis.contains("feelings"),
                      "Fallback should preserve a snippet of the raw output for debugging")
    }

    func testParseTreatsLiteralNullAsNil() {
        let raw = #"""
        {"diagnosis":"x","fixType":"retry_with_different_args","alternativeSkillName":"null","updatedInstructions":"null","alternativeArgs":{}}
        """#
        let result = SkillCreator.parseDiagnostic(raw)
        XCTAssertNil(result.alternativeSkillName,
                     "JSON literal \"null\" string must be mapped to nil")
        XCTAssertNil(result.updatedInstructions)
    }

    // MARK: - Prompt builders

    func testDiagnosticPromptIncludesAllInputs() {
        let step = PlanStep(id: "s1", description: "create event",
                            skillName: "calendar",
                            toolArgs: ["startTime": "tomorrow at 9am"])
        let prompt = SkillCreator.buildDiagnosticPrompt(
            failedStep: step,
            error: "DateTimeParseException: cannot parse 'tomorrow at 9am'",
            deviceInfo: "iPhone 17 Pro, iOS 18.0",
            skillInstructions: "Use yyyy-MM-ddTHH:mm format.",
            pastRepairs: "Previously tried HH:mm only — failed")
        XCTAssertTrue(prompt.contains("create event"))
        XCTAssertTrue(prompt.contains("calendar"))
        XCTAssertTrue(prompt.contains("DateTimeParseException"))
        XCTAssertTrue(prompt.contains("iPhone 17 Pro"))
        XCTAssertTrue(prompt.contains("yyyy-MM-ddTHH:mm format"))
        XCTAssertTrue(prompt.contains("Previously tried HH:mm only"))
        XCTAssertTrue(prompt.contains("retry_with_different_args"))
    }

    func testSkillCreationPromptCapturesAllSteps() {
        let plan = ExecutionPlan(goal: "summarize wiki on tokyo", reasoning: "r", steps: [
            PlanStep(id: "s1", description: "fetch", skillName: "fetch-web-content",
                     toolArgs: ["url": "https://en.wikipedia.org/wiki/Tokyo"]),
            PlanStep(id: "s2", description: "summarize",
                     skillName: "summarize",
                     dependsOn: ["s1"]),
        ])
        let results = [
            "s1": StepResult(stepId: "s1", status: .completed, output: "..."),
            "s2": StepResult(stepId: "s2", status: .completed, output: "..."),
        ]
        let prompt = SkillCreator.buildSkillCreationPrompt(
            skillName: "wikipedia-summary",
            userMessage: "summarize tokyo",
            plan: plan,
            results: results)
        XCTAssertTrue(prompt.contains("name: wikipedia-summary"))
        XCTAssertTrue(prompt.contains("summarize tokyo"))
        XCTAssertTrue(prompt.contains("fetch-web-content"))
        XCTAssertTrue(prompt.contains("summarize"))
        XCTAssertTrue(prompt.contains("depends on: s1"))
    }

    // MARK: - End-to-end diagnose

    func testDiagnoseReturnsParsedResult() async {
        let llm = StubLLM(#"""
        ```json
        {"diagnosis":"bad args","fixType":"retry_with_different_args","alternativeArgs":{"x":"1"}}
        ```
        """#)
        let creator = SkillCreator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let step = PlanStep(id: "s1", description: "x", skillName: "y")
        let result = await creator.diagnose(failedStep: step, error: "boom")
        XCTAssertEqual(result.fixType, "retry_with_different_args")
        XCTAssertEqual(result.alternativeArgs["x"], "1")
    }
}

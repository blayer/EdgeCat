import XCTest
@testable import EdgeCat

final class SelfEvaluatorTriageTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        var called = false
        func generateResponse(prompt: String, enableThinking: Bool, maxOutputTokens: Int) async throws -> String {
            called = true
            return #"{"goalAchieved":false,"assessment":"llm-said-no","shouldReplan":true}"#
        }
        func cancel() {}
    }

    private func plan(goal: String,
                      steps: [PlanStep],
                      criteria: [String] = []) -> ExecutionPlan {
        ExecutionPlan(goal: goal, reasoning: "r", steps: steps, successCriteria: criteria)
    }

    func testHappyPathTriagesToGoalAchievedWithoutLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "calculate total cost",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "calculator")],
                     criteria: ["total cost computed"])
        let results = ["s1": StepResult(stepId: "s1", status: .completed,
                                        output: "the total cost is $42.50")]
        let result = try await evaluator.evaluate(
            userMessage: "what's the total cost", plan: p, results: results)
        XCTAssertTrue(result.goalAchieved)
        XCTAssertEqual(result.assessment, "triage-shortcut")
        XCTAssertFalse(llm.called, "Triage hit must not call the LLM evaluator")
    }

    func testFailedStepFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "fetch wikipedia",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "fetch")])
        let results = ["s1": StepResult(stepId: "s1", status: .failed,
                                        output: "", error: "network down")]
        _ = try await evaluator.evaluate(
            userMessage: "wiki this", plan: p, results: results)
        XCTAssertTrue(llm.called, "Failed step should not be triaged")
    }

    func testEmptyOutputFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "calculate something",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "calculator")])
        let results = ["s1": StepResult(stepId: "s1", status: .completed, output: "")]
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: results)
        XCTAssertTrue(llm.called, "Empty output should not be triaged")
    }

    func testErrorMarkerInOutputFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "create event",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "calendar")])
        let results = ["s1": StepResult(stepId: "s1", status: .completed,
                                        output: "Error: permission denied")]
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: results)
        XCTAssertTrue(llm.called, "Output containing 'error' must not be triaged")
    }

    func testGoalTokenAbsentFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "find restaurant near me",
                     steps: [PlanStep(id: "s1", description: "x", skillName: "search")])
        // Output has nothing matching "restaurant"/"near"/"find" tokens.
        let results = ["s1": StepResult(stepId: "s1", status: .completed,
                                        output: "weather is 72 degrees")]
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: results)
        XCTAssertTrue(llm.called,
                      "Output that doesn't intersect goal tokens must not be triaged")
    }

    func testEmptyPlanFallsThroughToLlm() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "x", steps: [])
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: [:])
        XCTAssertTrue(llm.called, "Empty plan should not triage to success")
    }

    func testBareSearchResultsDoNotTriageAsSuccess() async throws {
        // Token "tokyo" is in both goal and search-result titles, which
        // would normally trigger the triage shortcut. But search results
        // alone aren't an answer — must fall through to the LLM evaluator
        // so it can ask for a fetch-web-content follow-up.
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "weather in Tokyo",
                     steps: [PlanStep(id: "s1", description: "search",
                                      skillName: "search-web")])
        let results = ["s1": StepResult(
            stepId: "s1", status: .completed,
            output: "Search results for: weather in Tokyo\n\n1. Tokyo - weather.com")]
        _ = try await evaluator.evaluate(
            userMessage: "weather in Tokyo", plan: p, results: results)
        XCTAssertTrue(llm.called,
                      "Bare search-results output must not satisfy triage")
    }

    func testIsBareSearchResultsHelper() {
        // No "Page content from" → bare list, must force replan.
        XCTAssertTrue(SelfEvaluator.isBareSearchResults(
            "Search results for: weather in Tokyo\n\n1. Tokyo - weather.com"))
        // With fetched content → triage can apply normally.
        XCTAssertFalse(SelfEvaluator.isBareSearchResults("""
        Search results for: weather in Tokyo

        Page content from https://weather.com/tokyo

        Tokyo today: cloudy, 18°C.
        """))
        // Non-search outputs aren't affected.
        XCTAssertFalse(SelfEvaluator.isBareSearchResults("the answer is 42"))
    }

    // MARK: - Write-side gate (state-calendar-001 regression)

    func testCalendarAddDoesNotTriageAsSuccess() async throws {
        // CalendarSkill.add returns a structured success envelope echoing
        // title/calendar — its tokens trivially overlap goal tokens. But
        // the OS-level EKEvent.save() can silently fail on the sim. Force
        // the LLM judge so the eval verifier discrepancy gets caught.
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "Add a calendar event called 'iOS Eval Test'",
                     steps: [PlanStep(id: "s1", description: "add event",
                                      skillName: "calendar",
                                      toolArgs: ["action": "add",
                                                 "title": "iOS Eval Test",
                                                 "startIso": "2026-04-30T14:00"])])
        let results = ["s1": StepResult(
            stepId: "s1", status: .completed,
            output: #"{"status":"succeeded","title":"iOS Eval Test","calendar":"Calendar"}"#)]
        _ = try await evaluator.evaluate(
            userMessage: "x", plan: p, results: results)
        XCTAssertTrue(llm.called, "calendar action=add must force LLM judge")
    }

    func testCalendarReadDefaultStillTriages() async throws {
        // Read-only calendar invocations should still hit the fast path.
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "what's on my calendar tomorrow",
                     steps: [PlanStep(id: "s1", description: "read",
                                      skillName: "calendar")],
                     criteria: ["upcoming events listed"])
        let results = ["s1": StepResult(
            stepId: "s1", status: .completed,
            output: "1. Team Meeting tomorrow at 10:00 (Calendar)")]
        let r = try await evaluator.evaluate(
            userMessage: "what's on my calendar tomorrow",
            plan: p, results: results)
        XCTAssertEqual(r.assessment, "triage-shortcut",
                       "Default-read calendar should keep the shortcut")
        XCTAssertFalse(llm.called)
    }

    func testRemindersAlwaysWriteSide() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "remind me to call mom",
                     steps: [PlanStep(id: "s1", description: "create reminder",
                                      skillName: "reminders",
                                      toolArgs: ["title": "Call mom"])])
        let results = ["s1": StepResult(
            stepId: "s1", status: .completed,
            output: #"{"status":"ok","reminderId":"abc","title":"Call mom"}"#)]
        _ = try await evaluator.evaluate(
            userMessage: "remind me to call mom", plan: p, results: results)
        XCTAssertTrue(llm.called, "reminders is always write-side")
    }

    func testTimerStartIsWriteSide() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        // No `action` arg → defaults to start (TimerSkill.swift:35).
        let p = plan(goal: "set a 10 minute timer",
                     steps: [PlanStep(id: "s1", description: "start",
                                      skillName: "timer",
                                      toolArgs: ["minutes": "10"])])
        let results = ["s1": StepResult(
            stepId: "s1", status: .completed,
            output: #"{"status":"ok","label":"timer","seconds":600}"#)]
        _ = try await evaluator.evaluate(
            userMessage: "set a 10 minute timer", plan: p, results: results)
        XCTAssertTrue(llm.called, "timer start must force LLM judge")
    }

    func testTimerListStillTriages() async throws {
        let llm = StubLLM()
        let evaluator = SelfEvaluator(llm: llm, policy: ThinkingPolicy(mode: .off))
        let p = plan(goal: "what timers are running",
                     steps: [PlanStep(id: "s1", description: "list",
                                      skillName: "timer",
                                      toolArgs: ["action": "list"])],
                     criteria: ["timers listed"])
        let results = ["s1": StepResult(
            stepId: "s1", status: .completed,
            output: "1. workout (running, 5m left)")]
        let r = try await evaluator.evaluate(
            userMessage: "what timers are running", plan: p, results: results)
        XCTAssertEqual(r.assessment, "triage-shortcut",
                       "timer action=list is read-side; shortcut should apply")
        XCTAssertFalse(llm.called)
    }

    func testIsWriteSideStepHelper() {
        XCTAssertTrue(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "send-sms")))
        XCTAssertTrue(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "reminders")))
        XCTAssertTrue(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "share-content")))
        XCTAssertTrue(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "calendar",
                     toolArgs: ["action": "add"])))
        XCTAssertFalse(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "calendar",
                     toolArgs: ["action": "read"])))
        XCTAssertFalse(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "calendar")))  // default = read
        XCTAssertTrue(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "clipboard",
                     toolArgs: ["action": "write", "text": "x"])))
        XCTAssertFalse(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "clipboard",
                     toolArgs: ["action": "read"])))
        XCTAssertFalse(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "calculator")))
        XCTAssertFalse(SelfEvaluator.isWriteSideStep(
            PlanStep(id: "s1", description: "x", skillName: "search-web")))
    }
}

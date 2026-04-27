import XCTest
@testable import MobileClaw

/// `buildReplanPrompt` must include enough state for the LLM to fix what
/// went wrong: prior plan, step outputs, evaluator feedback. Mirrors the
/// data-bearing parts of `android-app/.../Planner.kt::buildReplanPrompt`.
final class PlannerReplanPromptTests: XCTestCase {

    private func makePlan() -> ExecutionPlan {
        ExecutionPlan(goal: "book meeting tomorrow at 3pm",
                      reasoning: "use calendar skill",
                      steps: [
                        PlanStep(id: "s1", description: "create event",
                                 skillName: "calendar"),
                      ],
                      successCriteria: ["event created"])
    }

    private func makeResults() -> [String: StepResult] {
        ["s1": StepResult(stepId: "s1", status: .failed,
                          output: "no calendar permission",
                          error: "permission denied")]
    }

    func testReplanPromptContainsPriorGoalAndStepOutputs() {
        let prompt = Planner.buildReplanPrompt(
            userMessage: "book meeting tomorrow at 3pm",
            skills: [SkillSummary(name: "calendar", description: "calendar CRUD")],
            priorPlan: makePlan(),
            priorResults: makeResults(),
            evaluation: EvaluationResult(goalAchieved: false,
                                          assessment: "calendar failed",
                                          missingItems: ["event creation"],
                                          shouldReplan: true,
                                          failedCriteria: ["event created"]))
        XCTAssertTrue(prompt.contains("Previous goal: book meeting tomorrow at 3pm"))
        XCTAssertTrue(prompt.contains("s1 [failed]"))
        XCTAssertTrue(prompt.contains("no calendar permission"))
    }

    func testReplanPromptContainsEvaluatorFeedback() {
        let prompt = Planner.buildReplanPrompt(
            userMessage: "x", skills: [],
            priorPlan: makePlan(), priorResults: makeResults(),
            evaluation: EvaluationResult(goalAchieved: false,
                                          assessment: "calendar perms missing",
                                          missingItems: ["event"],
                                          shouldReplan: true,
                                          failedCriteria: ["event created"]))
        XCTAssertTrue(prompt.contains("calendar perms missing"))
        XCTAssertTrue(prompt.contains("Missing: event"))
        XCTAssertTrue(prompt.contains("Failed criteria: event created"))
    }

    func testReplanPromptIncludesPortraitAndMemoryWhenProvided() {
        let prompt = Planner.buildReplanPrompt(
            userMessage: "x", skills: [],
            priorPlan: makePlan(), priorResults: makeResults(),
            evaluation: EvaluationResult(goalAchieved: false, assessment: "x", shouldReplan: true),
            userPortrait: "uses google calendar",
            memoryContext: "prior episode: succeeded last week")
        XCTAssertTrue(prompt.contains("uses google calendar"))
        XCTAssertTrue(prompt.contains("prior episode: succeeded last week"))
    }

    func testPlanPromptIncludesDateNoteAndJsonTrailer() {
        let prompt = Planner.buildPlanPrompt(userMessage: "hi", skills: [])
        XCTAssertTrue(prompt.contains("yyyy-MM-ddTHH:mm"),
                      "Date format guidance must be in every plan prompt")
        XCTAssertTrue(prompt.contains("Respond with strict JSON"))
        XCTAssertTrue(prompt.contains("User request: hi"))
    }

    func testPlanPromptIncludesMemoryWhenProvided() {
        let prompt = Planner.buildPlanPrompt(
            userMessage: "x", skills: [],
            memoryContext: "prior: user prefers vegetarian recipes")
        XCTAssertTrue(prompt.contains("Relevant prior episodes:"))
        XCTAssertTrue(prompt.contains("user prefers vegetarian recipes"))
    }
}

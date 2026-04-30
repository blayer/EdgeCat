import XCTest
@testable import EdgeCat

/// `RunSummary` is the value type behind the `{"type":"run","run":{…}}`
/// line at the end of every eval trace. Off-device scorers in
/// `test/eval/scorers/` parse this dict directly. Schema parity tests
/// here protect against silent breakage of those scorers.
final class RunSummaryTests: XCTestCase {

    private func makeSummary(finalStatus: String = "ok",
                             plan: ExecutionPlan? = nil,
                             evaluation: EvaluationResult? = nil,
                             error: String? = nil) -> RunSummary {
        RunSummary(
            runId: "test-run",
            userMessage: "what's 2+2",
            finalStatus: finalStatus,
            finalOutput: "4",
            iteration: 0,
            startMs: 1_000,
            endMs: 1_350,
            plan: plan,
            stepResults: [:],
            evaluation: evaluation,
            extras: ["model_name": "gemma-4-E2B-it",
                     "agentic": true,
                     "memory_isolated": true],
            device: ["manufacturer": "Apple", "model": "iPhone",
                     "system_version": "18.0"],
            error: error)
    }

    func testToDictionaryPopulatesRequiredKeys() {
        let dict = makeSummary().toDictionary()
        XCTAssertEqual(dict["run_id"] as? String, "test-run")
        XCTAssertEqual(dict["schema_version"] as? Int, 1)
        XCTAssertEqual(dict["user_message"] as? String, "what's 2+2")
        XCTAssertEqual(dict["final_status"] as? String, "ok")
        XCTAssertEqual(dict["final_output"] as? String, "4")
        XCTAssertEqual(dict["iteration"] as? Int, 0)
        XCTAssertEqual(dict["start_ms"] as? Int64, 1_000)
        XCTAssertEqual(dict["end_ms"] as? Int64, 1_350)
        XCTAssertEqual(dict["duration_ms"] as? Int64, 350)
    }

    func testExtrasAndDeviceBlocksPreserved() {
        let dict = makeSummary().toDictionary()
        let extras = dict["extras"] as? [String: Any]
        XCTAssertEqual(extras?["model_name"] as? String, "gemma-4-E2B-it")
        XCTAssertEqual(extras?["memory_isolated"] as? Bool, true)
        let device = dict["device"] as? [String: Any]
        XCTAssertEqual(device?["manufacturer"] as? String, "Apple")
    }

    func testPlanEncodingSnakeCase() {
        let plan = ExecutionPlan(
            goal: "calc 2+2",
            reasoning: "single step",
            steps: [PlanStep(id: "s1", description: "compute",
                              skillName: "calculator",
                              toolArgs: ["expression": "2+2"])],
            successCriteria: ["correct number"])
        let dict = makeSummary(plan: plan).toDictionary()
        let planDict = dict["plan"] as? [String: Any]
        XCTAssertEqual(planDict?["goal"] as? String, "calc 2+2")
        XCTAssertEqual(planDict?["success_criteria"] as? [String], ["correct number"])
        let steps = planDict?["steps"] as? [[String: Any]]
        XCTAssertEqual(steps?.first?["skill_name"] as? String, "calculator",
                       "Steps must use snake_case skill_name (Android scorer key)")
        XCTAssertEqual(steps?.first?["tool_args"] as? [String: String],
                       ["expression": "2+2"])
    }

    func testEvaluationEncodingSnakeCase() {
        let eval = EvaluationResult(
            goalAchieved: true,
            assessment: "all good",
            missingItems: [],
            shouldReplan: false,
            failedCriteria: [])
        let dict = makeSummary(evaluation: eval).toDictionary()
        let evalDict = dict["evaluation"] as? [String: Any]
        XCTAssertEqual(evalDict?["goal_achieved"] as? Bool, true)
        XCTAssertEqual(evalDict?["should_replan"] as? Bool, false)
        XCTAssertEqual(evalDict?["missing_items"] as? [String], [])
    }

    func testErrorPathPopulatesErrorField() {
        let dict = makeSummary(finalStatus: "error",
                                error: "model_init_timeout").toDictionary()
        XCTAssertEqual(dict["final_status"] as? String, "error")
        XCTAssertEqual(dict["error"] as? String, "model_init_timeout")
    }

    func testJSONSerializableTopLevel() throws {
        let dict = makeSummary().toDictionary()
        let data = try JSONSerialization.data(withJSONObject: dict)
        let roundTrip = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(roundTrip?["run_id"] as? String, "test-run")
    }
}

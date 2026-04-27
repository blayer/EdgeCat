import XCTest
@testable import MobileClaw

/// After a successful orchestration run, `OrchestrationController.handle`
/// must call `MemoryProvider.saveEpisode` so future plans can recall it.
/// Failed / partial runs must not pollute memory.
final class MemoryWriteBackTests: XCTestCase {

    private final class StubLLM: LlmInferenceProvider, @unchecked Sendable {
        var responses: [String]
        init(_ responses: [String]) { self.responses = responses }
        func generateResponse(prompt: String, enableThinking: Bool) async throws -> String {
            responses.isEmpty ? "{}" : responses.removeFirst()
        }
        func cancel() {}
    }

    private final class StubTools: ToolExecutor, @unchecked Sendable {
        let outputs: [String: ToolExecutionResult]
        init(_ outputs: [String: ToolExecutionResult] = [:]) { self.outputs = outputs }
        func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
            outputs[toolName] ?? ToolExecutionResult(success: true, output: "ok")
        }
        func getAvailableSkills() -> [SkillSummary] {
            [SkillSummary(name: "calculator", description: "math")]
        }
    }

    private final class RecordingMemory: MemoryProvider, @unchecked Sendable {
        let lock = NSLock()
        var saved: [OrchestrationEpisode] = []
        let recall: String
        init(recall: String = "") { self.recall = recall }
        func recallForPlanning(userMessage: String) async -> String { recall }
        func saveEpisode(_ episode: OrchestrationEpisode) async {
            lock.lock(); saved.append(episode); lock.unlock()
        }
    }

    @MainActor
    func testSuccessfulRunSavesEpisode() async throws {
        let llm = StubLLM([
            // plan
            #"""
            {"goal":"add 2+2","reasoning":"r","steps":[{"id":"s1","description":"calc","skillName":"calculator","toolArgs":{"expression":"2+2"}}]}
            """#,
            // evaluator → goalAchieved
            #"""
            {"goalAchieved":true,"assessment":"good","shouldReplan":false}
            """#,
        ])
        let memory = RecordingMemory()
        let ctrl = OrchestrationController(
            llm: llm,
            tools: StubTools(["calculate": ToolExecutionResult(success: true, output: "4")]),
            policy: ThinkingPolicy(mode: .off),
            memory: memory)
        let final = try await ctrl.handle(userMessage: "what's 2+2")
        XCTAssertEqual(final, "4")
        XCTAssertEqual(memory.saved.count, 1, "Successful run must save exactly one episode")
        let episode = memory.saved[0]
        XCTAssertEqual(episode.userMessage, "what's 2+2")
        XCTAssertEqual(episode.goal, "add 2+2")
        XCTAssertEqual(episode.skillsUsed, ["calculator"])
        XCTAssertEqual(episode.outcome, "success")
        XCTAssertEqual(episode.finalOutput, "4")
    }

    @MainActor
    func testFailedRunDoesNotSaveEpisode() async throws {
        // shouldReplan=false + goalAchieved=false → controller terminates
        // and formats best-effort, but should NOT save the episode.
        let llm = StubLLM([
            #"""
            {"goal":"x","reasoning":"r","steps":[{"id":"s1","description":"x","toolName":"alpha"}]}
            """#,
            #"""
            {"goalAchieved":false,"assessment":"failed","shouldReplan":false}
            """#,
            "synthesized fallback",
        ])
        let memory = RecordingMemory()
        let ctrl = OrchestrationController(
            llm: llm,
            tools: StubTools(["alpha": ToolExecutionResult(success: false, error: "boom")]),
            policy: ThinkingPolicy(mode: .off),
            memory: memory)
        _ = try await ctrl.handle(userMessage: "do something")
        XCTAssertEqual(memory.saved.count, 0,
                       "Failed run should not pollute memory recall")
    }
}

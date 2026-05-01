import XCTest
@testable import EdgeCat

/// Memory recall must reach the planner prompt. Uses a fake `MemoryProvider`
/// that returns a known string and a recording LLM that captures the prompt
/// it sees. Asserts the recorded prompt contains the recalled context.
final class OrchestrationMemoryWiringTests: XCTestCase {

    private final class RecordingLLM: LlmInferenceProvider, @unchecked Sendable {
        let lock = NSLock()
        var prompts: [String] = []
        let canned: String
        init(canned: String) { self.canned = canned }
        func generateResponse(prompt: String, enableThinking: Bool, maxOutputTokens: Int) async throws -> String {
            lock.lock(); prompts.append(prompt); lock.unlock()
            return canned
        }
        func cancel() {}
    }

    private final class StubTools: ToolExecutor, @unchecked Sendable {
        func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
            ToolExecutionResult(success: true, output: "ok")
        }
        func getAvailableSkills() -> [SkillSummary] {
            [SkillSummary(name: "calendar", description: "calendar")]
        }
    }

    private struct StaticMemory: MemoryProvider {
        let recall: String
        func recallForPlanning(userMessage: String) async -> String { recall }
    }

    @MainActor
    func testMemoryRecallReachesPlannerPrompt() async throws {
        // Plan response stays minimal so the loop completes in one iteration
        // (goalAchieved=true path in the evaluator stub by way of the empty
        // step list — evaluator default is goalAchieved=true).
        let llm = RecordingLLM(canned: """
        {"goal":"x","reasoning":"r","steps":[]}
        """)
        let controller = OrchestrationController(
            llm: llm, tools: StubTools(),
            policy: ThinkingPolicy(mode: .off),
            memory: StaticMemory(recall: "prior: user always confirms before booking"))

        _ = try await controller.handle(userMessage: "book a meeting")

        XCTAssertFalse(llm.prompts.isEmpty, "Planner should have been invoked")
        let plannerPrompt = try XCTUnwrap(llm.prompts.first)
        XCTAssertTrue(
            plannerPrompt.contains("Relevant prior episodes:"),
            "Memory section must be in the prompt")
        XCTAssertTrue(
            plannerPrompt.contains("prior: user always confirms before booking"),
            "Recalled memory text must be in the prompt")
        XCTAssertTrue(controller.state.memoryRecalled == true)
    }

    @MainActor
    func testEmptyMemoryProviderOmitsSection() async throws {
        let llm = RecordingLLM(canned: """
        {"goal":"x","reasoning":"r","steps":[]}
        """)
        let controller = OrchestrationController(
            llm: llm, tools: StubTools(),
            policy: ThinkingPolicy(mode: .off))
        _ = try await controller.handle(userMessage: "x")

        let plannerPrompt = try XCTUnwrap(llm.prompts.first)
        XCTAssertFalse(plannerPrompt.contains("Relevant prior episodes:"),
                       "Memory section must be omitted when nothing is recalled")
        XCTAssertEqual(controller.state.memoryRecalled, false)
    }

    @MainActor
    func testConversationContextProviderReachesPrompt() async throws {
        let llm = RecordingLLM(canned: """
        {"goal":"x","reasoning":"r","steps":[]}
        """)
        let controller = OrchestrationController(
            llm: llm, tools: StubTools(),
            policy: ThinkingPolicy(mode: .off),
            conversationContext: { "user: previously asked about pasta" })
        _ = try await controller.handle(userMessage: "what's for dinner?")

        let plannerPrompt = try XCTUnwrap(llm.prompts.first)
        XCTAssertTrue(plannerPrompt.contains("Recent conversation:"))
        XCTAssertTrue(plannerPrompt.contains("previously asked about pasta"))
    }
}

import XCTest
@testable import EdgeCat

/// `OrchestrationController.cancel()` must cause `handle()` to throw
/// `OrchestrationError.cancelled` at the next phase boundary, and must
/// also tell the LLM provider to abort any in-flight inference.
final class OrchestrationCancellationTests: XCTestCase {

    private final class CancellableLLM: LlmInferenceProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelCalled = false
        var cancelCalled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _cancelCalled
        }
        var responses: [String]
        init(_ responses: [String]) { self.responses = responses }
        func generateResponse(prompt: String, enableThinking: Bool, maxOutputTokens: Int) async throws -> String {
            responses.isEmpty ? "{}" : responses.removeFirst()
        }
        func cancel() {
            lock.lock(); _cancelCalled = true; lock.unlock()
        }
    }

    private final class StubTools: ToolExecutor, @unchecked Sendable {
        func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
            ToolExecutionResult(success: true, output: "ok")
        }
        func getAvailableSkills() -> [SkillSummary] { [] }
    }

    @MainActor
    func testCancelMidRunStopsTheLoop() async {
        // The executor itself triggers cancel during step execution — the
        // most reliable way to exercise mid-run cancellation without
        // timing flakiness. Mirrors how the chat UI's Stop button reaches
        // the controller from a sibling Task: by the next phase boundary
        // (`throwIfCancelled` after execute returns), the loop bails out.
        let llm = CancellableLLM([
            #"""
            {"goal":"x","reasoning":"r","steps":[{"id":"s1","description":"x","toolName":"alpha"}]}
            """#,
        ])
        final class CancellingExec: ToolExecutor, @unchecked Sendable {
            let cancelHook: @Sendable () async -> Void
            init(_ cancelHook: @escaping @Sendable () async -> Void) {
                self.cancelHook = cancelHook
            }
            func executeTool(toolName: String, args: [String: String]) async -> ToolExecutionResult {
                await cancelHook()
                return ToolExecutionResult(success: true, output: "ok")
            }
            func getAvailableSkills() -> [SkillSummary] { [] }
        }
        // Build controller first, then the executor with a closure that
        // captures it weakly. cancellingExec sets `cancelRequested` directly
        // by calling ctrl.cancel() from the tool execution.
        var ctrlBox: OrchestrationController?
        let exec = CancellingExec {
            await MainActor.run { ctrlBox?.cancel() }
        }
        let ctrl = OrchestrationController(
            llm: llm, tools: exec,
            policy: ThinkingPolicy(mode: .off))
        ctrlBox = ctrl

        do {
            _ = try await ctrl.handle(userMessage: "do")
            XCTFail("Expected cancellation throw")
        } catch let err as OrchestrationError {
            XCTAssertEqual(err, .cancelled)
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    @MainActor
    func testCancelPropagatesToLlmProvider() {
        // Direct contract test: ctrl.cancel() forwards to llm.cancel()
        // immediately, no async timing involved. Mirrors Android's
        // `cancelled.set(true); llmProvider.cancel()`.
        let llm = CancellableLLM([])
        let ctrl = OrchestrationController(
            llm: llm, tools: StubTools(),
            policy: ThinkingPolicy(mode: .off))
        XCTAssertFalse(llm.cancelCalled)
        ctrl.cancel()
        XCTAssertTrue(llm.cancelCalled,
                      "cancel() must forward to the injected LLM provider")
    }

    @MainActor
    func testCancelIsResetOnNextHandle() async throws {
        let llm = CancellableLLM([
            "{}", // first call: cancelled before it matters, but reset on next handle
            #"""
            {"goal":"x","reasoning":"r","steps":[]}
            """#,
            #"""
            {"goalAchieved":true,"shouldReplan":false}
            """#,
        ])
        let ctrl = OrchestrationController(
            llm: llm, tools: StubTools(),
            policy: ThinkingPolicy(mode: .off))
        ctrl.cancel()
        _ = try? await ctrl.handle(userMessage: "first")

        // Second handle must succeed (cancellation flag reset on entry).
        let final = try await ctrl.handle(userMessage: "second")
        XCTAssertFalse(final.isEmpty,
                       "cancelRequested should be cleared at the start of each handle()")
    }
}

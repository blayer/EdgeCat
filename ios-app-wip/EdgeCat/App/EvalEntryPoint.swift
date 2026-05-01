import Foundation
import UIKit

// Mirrors android-app/.../eval/EvalActivity.kt — the URL-driven entry
// point for the eval harness. Off-device runner (`test/eval/run.py`)
// invokes the app via:
//
//   xcrun simctl launch --setenv EDGECAT_EVAL_MODE=1 <udid> <bundle-id>
//   xcrun simctl openurl <udid> \
//     "edgecat://eval?prompt=hello&model=gemma-4-E2B-it.litertlm&runId=test1&agentic=1"
//
// EvalRunnerView (rendered when EDGECAT_EVAL_MODE=1) shows a minimal
// status pill backed by `EvalRunStatus`. This entry point spawns the
// orchestrator headlessly, writes a JSONL trace + run-summary line to
// `Documents/edgecat-traces/<runId>.jsonl`, then emits an `eval-complete`
// sentinel so the off-device file-stability poller knows the file is
// final.
//
// Multi-turn: a same-runId URL with `&continue=1` keeps the session
// alive after the turn completes. The next URL with the same runId
// appends another turn, with the prior (user, assistant) pairs surfaced
// to the orchestrator via `conversationContext`. The terminal turn
// (continue absent or 0) emits `eval-complete` + `RunSummary` and
// disposes the session. Conversation history is held in an in-memory
// `HistoryHolder` (no SwiftData / Conversation row write-back) and
// dropped on dispose, mirroring the Android `EvalActivity` invariant
// that eval messages must not leak into the user's chat history.

public enum EvalEntryPoint {

    /// Conversation history for the active session. Populated per-turn
    /// in-memory only; deallocated when the session disposes.
    private final class HistoryHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(user: String, assistant: String)] = []
        private let window: Int
        init(window: Int = 6) { self.window = window }
        func append(user: String, assistant: String) {
            lock.lock(); defer { lock.unlock() }
            entries.append((user, assistant))
        }
        /// Renders the last `window` turns into a "User: …\nAssistant: …"
        /// string for the planner's `conversationContext` prompt slot.
        /// Empty for the first turn (no prior history).
        func formatted() -> String {
            lock.lock(); defer { lock.unlock() }
            let recent = entries.suffix(window)
            return recent.map { "User: \($0.user)\nAssistant: \($0.assistant)" }
                         .joined(separator: "\n")
        }
        func firstUser() -> String? {
            lock.lock(); defer { lock.unlock() }
            return entries.first?.user
        }
    }

    /// Active eval session — one at a time, possibly spanning multiple
    /// turns sharing a runId. Memory is purely in-process: when the
    /// session is released the engine, controller, and history holder
    /// are deallocated together. No chat-DB write-back.
    private final class ActiveSession: @unchecked Sendable {
        let runId: String
        let recorder: TraceRecorder
        let engine: LiteRtLmEngine
        let history: HistoryHolder
        let startMs: Int64
        let device: [String: Any]
        let modelFile: String?
        let agentic: Bool
        /// Set after engine init succeeds on the first turn. Subsequent
        /// turns require non-nil; `runTurn` short-circuits if it's nil
        /// (means engine init failed and the session is already on the
        /// teardown path).
        var controller: OrchestrationController?
        var turnIndex: Int  // 0-based; incremented after each turn completes.
        var lastFinalText: String
        var lastFinalStatus: String
        var lastError: String?
        var lastStepResults: [String: StepResult]
        var lastPlan: ExecutionPlan?
        var lastEval: EvaluationResult?
        var lastIteration: Int

        init(runId: String,
             recorder: TraceRecorder,
             engine: LiteRtLmEngine,
             history: HistoryHolder,
             startMs: Int64,
             device: [String: Any],
             modelFile: String?,
             agentic: Bool) {
            self.runId = runId
            self.recorder = recorder
            self.engine = engine
            self.history = history
            self.startMs = startMs
            self.device = device
            self.modelFile = modelFile
            self.agentic = agentic
            self.controller = nil
            self.turnIndex = 0
            self.lastFinalText = ""
            self.lastFinalStatus = "ok"
            self.lastStepResults = [:]
            self.lastIteration = 0
        }
    }

    /// Single-instance lock. A second `edgecat://eval` URL with a
    /// *different* runId while a session is in flight is rejected with
    /// an `eval-busy` span. A *same*-runId URL is accepted as the next
    /// turn of the active session.
    private enum InFlightOutcome { case acquired, continued, busy }

    private actor InFlight {
        private var current: ActiveSession?
        func acquireOrContinue(runId: String,
                               make: @Sendable () -> ActiveSession)
                              -> (InFlightOutcome, ActiveSession) {
            if let cur = current {
                if cur.runId == runId { return (.continued, cur) }
                return (.busy, cur)
            }
            let s = make()
            current = s
            return (.acquired, s)
        }
        func release(_ session: ActiveSession) {
            if current === session { current = nil }
        }
    }
    private static let inFlight = InFlight()

    /// Hard deadline on engine.initialize. Mirrors Android's 90s timeout.
    private static let modelInitTimeoutSeconds: UInt64 = 90

    @MainActor
    public static func handle(_ url: URL) {
        guard url.scheme == "edgecat" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        switch url.host {
        case "eval":
            let prompt = items.first(where: { $0.name == "prompt" })?.value ?? ""
            let modelFile = items.first(where: { $0.name == "model" })?.value
            let runId = items.first(where: { $0.name == "runId" })?.value ?? UUID().uuidString
            let agentic = items.first(where: { $0.name == "agentic" })?.value == "1"
            let keepAlive = items.first(where: { $0.name == "continue" })?.value == "1"
            Task.detached {
                await runTurn(prompt: prompt,
                              modelFile: modelFile,
                              runId: runId,
                              agentic: agentic,
                              keepAlive: keepAlive)
            }
        case "verify":
            let runId = items.first(where: { $0.name == "runId" })?.value ?? UUID().uuidString
            let kind = items.first(where: { $0.name == "kind" })?.value ?? ""
            var params: [String: String] = [:]
            for item in items where item.name != "runId" && item.name != "kind" {
                if let v = item.value { params[item.name] = v }
            }
            Task.detached {
                await StateVerifiers.runAndEmit(runId: runId, kind: kind, params: params)
            }
        default:
            return
        }
    }

    private static func runTurn(prompt: String,
                                modelFile: String?,
                                runId: String,
                                agentic: Bool,
                                keepAlive: Bool) async {
        let device = await MainActor.run { Self.deviceInfo() }

        // 1. Acquire-or-continue the active session.
        let make: @Sendable () -> ActiveSession = {
            ActiveSession(runId: runId,
                          recorder: TraceRecorder(runId: runId),
                          engine: LiteRtLmEngine(),
                          history: HistoryHolder(),
                          startMs: TraceRecorder.nowMs(),
                          device: device,
                          modelFile: modelFile,
                          agentic: agentic)
        }
        let (outcome, session) = await inFlight.acquireOrContinue(runId: runId, make: make)

        switch outcome {
        case .busy:
            await session.recorder.event(kind: "eval", name: "busy",
                                          payload: ["incoming_run_id": runId])
            return
        case .acquired:
            // First turn: validate, init engine, build controller.
            await session.recorder.event(kind: "eval", name: "start",
                                          payload: ["prompt": prompt,
                                                    "agentic": agentic ? "1" : "0",
                                                    "run_id": runId])
            await MainActor.run {
                EvalRunStatus.shared.begin(prompt: prompt, runId: runId,
                                            modelName: modelFile ?? "(default)")
            }
            guard !prompt.isEmpty, let modelURL = resolveModel(modelFile) else {
                await emitFailureAndDispose(session,
                                            error: "missing_prompt_or_model",
                                            prompt: prompt)
                return
            }
            do {
                try await withModelInitTimeout(seconds: Self.modelInitTimeoutSeconds) {
                    // 8192 instead of 4096: multi-turn cases pile
                    // conversation history into the planner prompt and
                    // the original 4K cap blew the token budget on
                    // turn 2+ ("Input token ids are too long: 4167
                    // >= 4096"). Gemma E2B/E4B supports 8K context.
                    try await session.engine.initialize(
                        config: LlmInitConfig(modelPath: modelURL, maxTokens: 8192))
                }
            } catch let timeout as ModelInitTimeout {
                await emitFailureAndDispose(session,
                                            error: "model_init_timeout: \(timeout.seconds)s",
                                            prompt: prompt)
                return
            } catch {
                await emitFailureAndDispose(session,
                                            error: "model_init_failed: \(error.localizedDescription)",
                                            prompt: prompt)
                return
            }
            // Build the real controller wired to a history-backed
            // conversationContext closure. The closure captures the
            // history holder weakly (via the session) so it always
            // reads the current entries.
            let holder = session.history
            let provider = LiteRtLmInferenceProvider(engine: session.engine)
            let controller = await MainActor.run { () -> OrchestrationController in
                OrchestrationController(
                    llm: provider,
                    tools: SkillRegistry.defaultSet(),
                    trace: session.recorder,
                    maxIterations: 3,
                    conversationContext: { holder.formatted() })
            }
            session.controller = controller
            await MainActor.run {
                EvalRunStatus.shared.transition(to: .running, detail: "Running…")
            }
        case .continued:
            // Same runId follow-up turn.
            await session.recorder.event(kind: "eval", name: "turn-start",
                                          payload: ["prompt": prompt,
                                                    "turn": String(session.turnIndex),
                                                    "run_id": runId])
            await MainActor.run {
                EvalRunStatus.shared.transition(to: .running,
                                                 detail: "Turn \(session.turnIndex + 1)…")
            }
        }

        // 2. Run the orchestrator (or plain chat) for this turn.
        var finalText = ""
        var finalStatus = "ok"
        var stepResults: [String: StepResult] = [:]
        var capturedPlan: ExecutionPlan?
        var capturedEval: EvaluationResult?
        var iteration = 0
        var errorMessage: String?
        do {
            if agentic {
                guard let controller = session.controller else {
                    throw NSError(domain: "EvalEntryPoint", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                            "controller_not_initialized"])
                }
                finalText = try await controller.handle(userMessage: prompt)
                let state = await controller.state
                stepResults = state.stepResults
                capturedPlan = state.plan
                capturedEval = state.evaluation
                iteration = state.iteration
            } else {
                var buffer = ""
                for try await token in session.engine.runInference(prompt: prompt) {
                    if token.isFinal { break }
                    buffer += token.text
                }
                finalText = buffer
            }
        } catch {
            finalStatus = "error"
            errorMessage = error.localizedDescription
        }

        // 3. Append to history; stash latest results for RunSummary.
        session.history.append(user: prompt, assistant: finalText)
        session.lastFinalText = finalText
        session.lastFinalStatus = finalStatus
        session.lastError = errorMessage
        session.lastStepResults = stepResults
        session.lastPlan = capturedPlan
        session.lastEval = capturedEval
        session.lastIteration = iteration

        // 4. Per-turn sentinel.
        await session.recorder.event(kind: "eval", name: "turn-complete",
                                      payload: ["status": finalStatus,
                                                "turn": String(session.turnIndex),
                                                "run_id": runId])
        session.turnIndex += 1

        // 5. Either keep the session alive for the next turn, or finalize.
        if keepAlive {
            await MainActor.run {
                EvalRunStatus.shared.transition(to: .running,
                                                 detail: "Awaiting next turn…")
            }
            return
        }
        await finalizeAndDispose(session)
    }

    private static func finalizeAndDispose(_ session: ActiveSession) async {
        let endMs = TraceRecorder.nowMs()
        let firstUserMessage = session.history.firstUser() ?? ""
        let summary = RunSummary(
            runId: session.runId,
            userMessage: firstUserMessage,
            finalStatus: session.lastFinalStatus,
            finalOutput: session.lastFinalText,
            iteration: session.lastIteration,
            startMs: session.startMs,
            endMs: endMs,
            plan: session.lastPlan,
            stepResults: session.lastStepResults,
            evaluation: session.lastEval,
            extras: extras(modelFile: session.modelFile,
                            agentic: session.agentic,
                            turns: session.turnIndex),
            device: session.device,
            error: session.lastError)
        await session.recorder.flushRunSummary(summary.toDictionary())
        await session.recorder.event(kind: "eval", name: "complete",
                                      payload: ["status": session.lastFinalStatus,
                                                "duration_ms": String(endMs - session.startMs),
                                                "turns": String(session.turnIndex),
                                                "run_id": session.runId])
        await MainActor.run {
            EvalRunStatus.shared.transition(
                to: session.lastFinalStatus == "ok" ? .completed : .failed,
                detail: session.lastFinalStatus == "ok" ? "Done" : (session.lastError ?? "Failed"))
        }
        await inFlight.release(session)
    }

    private static func emitFailureAndDispose(_ session: ActiveSession,
                                              error: String,
                                              prompt: String) async {
        let endMs = TraceRecorder.nowMs()
        let summary = RunSummary(
            runId: session.runId,
            userMessage: prompt,
            finalStatus: "error",
            finalOutput: "",
            iteration: 0,
            startMs: session.startMs,
            endMs: endMs,
            extras: extras(modelFile: nil, agentic: session.agentic, turns: 0),
            device: session.device,
            error: error)
        await session.recorder.flushRunSummary(summary.toDictionary())
        await session.recorder.event(kind: "eval", name: "complete",
                                      payload: ["status": "error",
                                                "error": error,
                                                "run_id": session.runId])
        await MainActor.run {
            EvalRunStatus.shared.transition(to: .failed, detail: error)
        }
        await inFlight.release(session)
    }

    // MARK: - Helpers

    private static func extras(modelFile: String?, agentic: Bool, turns: Int) -> [String: Any] {
        [
            "model_name": modelFile ?? "(default)",
            "agentic": agentic,
            "memory_isolated": true,
            "turns": turns,
        ]
    }

    @MainActor
    private static func deviceInfo() -> [String: Any] {
        var info: [String: Any] = [
            "manufacturer": "Apple",
            "model": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
        ]
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            info["idfv"] = idfv
        }
        return info
    }

    private static func resolveModel(_ file: String?) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("Models", isDirectory: true)
        guard let dir else { return nil }
        if let file, !file.isEmpty {
            return dir.appendingPathComponent(file)
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)) ?? []
        return contents.first(where: { $0.pathExtension.lowercased() == "litertlm" })
    }

    /// Race the model init against a sleep; whichever finishes first wins.
    private static func withModelInitTimeout(seconds: UInt64,
                                             _ block: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await block() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw ModelInitTimeout(seconds: seconds)
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private struct ModelInitTimeout: Error {
        let seconds: UInt64
    }
}

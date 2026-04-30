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
// `Documents/claw-traces/<runId>.jsonl`, then emits an `eval-complete`
// sentinel so the off-device file-stability poller knows the file is
// final.

public enum EvalEntryPoint {

    /// Single-instance lock. A second `edgecat://eval` URL while a
    /// previous run is still in flight is rejected with an `eval-busy`
    /// span on the active trace. Mirrors android-app's
    /// `EvalActivity` `noHistory=true` single-instance semantics.
    private actor InFlight {
        var current: TraceRecorder?
        func acquire(_ recorder: TraceRecorder) -> Bool {
            if current != nil { return false }
            current = recorder
            return true
        }
        func release(_ recorder: TraceRecorder) {
            if current === recorder { current = nil }
        }
        func active() -> TraceRecorder? { current }
    }
    private static let inFlight = InFlight()

    /// Hard deadline on engine.initialize. Mirrors Android's 90s timeout.
    /// Most loads complete in 5-15s; this catches stuck Metal-shader
    /// compilation or corrupt model files.
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
            Task.detached {
                await run(prompt: prompt,
                          modelFile: modelFile,
                          runId: runId,
                          agentic: agentic)
            }
        case "verify":
            // Off-device runner emits this URL after an eval completes
            // (or directly during a state-only test) to ask the app to
            // query an iOS API and emit a `kind=verify` span the
            // scorer reads. See `EdgeCat/Eval/StateVerifiers.swift`.
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

    private static func run(prompt: String,
                            modelFile: String?,
                            runId: String,
                            agentic: Bool) async {
        let recorder = TraceRecorder(runId: runId)
        // Capture device info up front on the MainActor so the rest of
        // this Task.detached body stays nonisolated.
        let device = await MainActor.run { Self.deviceInfo() }

        // 1. In-flight guard.
        let acquired = await inFlight.acquire(recorder)
        if !acquired {
            if let active = await inFlight.active() {
                await active.event(kind: "eval", name: "busy",
                                    payload: ["incoming_run_id": runId])
            }
            return
        }
        defer { Task { await inFlight.release(recorder) } }

        let startMs = TraceRecorder.nowMs()
        await recorder.event(kind: "eval", name: "start",
                              payload: ["prompt": prompt, "agentic": agentic ? "1" : "0",
                                        "run_id": runId])

        await MainActor.run {
            EvalRunStatus.shared.begin(prompt: prompt, runId: runId,
                                        modelName: modelFile ?? "(default)")
        }

        // 2. Validate prompt + model.
        guard !prompt.isEmpty, let modelURL = resolveModel(modelFile) else {
            await emitFailure(recorder, prompt: prompt, runId: runId,
                              startMs: startMs, agentic: agentic,
                              device: device,
                              error: "missing_prompt_or_model")
            return
        }

        // 3. Init engine with a 90s hard deadline.
        let engine = LiteRtLmEngine()
        do {
            try await withModelInitTimeout(seconds: Self.modelInitTimeoutSeconds) {
                try await engine.initialize(config: LlmInitConfig(modelPath: modelURL,
                                                                   maxTokens: 4096))
            }
        } catch let timeout as ModelInitTimeout {
            await emitFailure(recorder, prompt: prompt, runId: runId,
                              startMs: startMs, agentic: agentic,
                              device: device,
                              error: "model_init_timeout: \(timeout.seconds)s")
            return
        } catch {
            await emitFailure(recorder, prompt: prompt, runId: runId,
                              startMs: startMs, agentic: agentic,
                              device: device,
                              error: "model_init_failed: \(error.localizedDescription)")
            return
        }

        await MainActor.run {
            EvalRunStatus.shared.transition(to: .running, detail: "Running…")
        }

        // 4. Run the orchestrator (or plain chat). Memory is isolated by
        //    construction — `OrchestrationController`'s default
        //    `EmptyMemoryProvider` ensures no SwiftData write-back.
        var finalText = ""
        var finalStatus = "ok"
        var stepResults: [String: StepResult] = [:]
        var capturedPlan: ExecutionPlan?
        var capturedEval: EvaluationResult?
        var iteration = 0
        var errorMessage: String?

        do {
            if agentic {
                let provider = LiteRtLmInferenceProvider(engine: engine)
                let tools = await MainActor.run { SkillRegistry.defaultSet() }
                let controller = await MainActor.run {
                    OrchestrationController(llm: provider, tools: tools,
                                            trace: recorder, maxIterations: 3)
                }
                finalText = try await controller.handle(userMessage: prompt)
                let state = await controller.state
                stepResults = state.stepResults
                capturedPlan = state.plan
                capturedEval = state.evaluation
                iteration = state.iteration
            } else {
                var buffer = ""
                for try await token in engine.runInference(prompt: prompt) {
                    if token.isFinal { break }
                    buffer += token.text
                }
                finalText = buffer
            }
        } catch {
            finalStatus = "error"
            errorMessage = error.localizedDescription
        }

        let endMs = TraceRecorder.nowMs()

        // 5. Emit RunSummary line.
        let summary = RunSummary(
            runId: runId,
            userMessage: prompt,
            finalStatus: finalStatus,
            finalOutput: finalText,
            iteration: iteration,
            startMs: startMs,
            endMs: endMs,
            plan: capturedPlan,
            stepResults: stepResults,
            evaluation: capturedEval,
            extras: extras(modelFile: modelFile, agentic: agentic),
            device: device,
            error: errorMessage)
        await recorder.flushRunSummary(summary.toDictionary())

        // 6. Sentinel — definite end-of-write for the stability poller.
        await recorder.event(kind: "eval", name: "complete",
                              payload: ["status": finalStatus,
                                        "duration_ms": String(endMs - startMs),
                                        "run_id": runId])

        // 7. Update the headless view.
        await MainActor.run {
            EvalRunStatus.shared.transition(
                to: finalStatus == "ok" ? .completed : .failed,
                detail: finalStatus == "ok" ? "Done" : (errorMessage ?? "Failed"))
        }
    }

    // MARK: - Helpers

    // swiftlint:disable:next function_parameter_count
    private static func emitFailure(_ recorder: TraceRecorder,
                                    prompt: String,
                                    runId: String,
                                    startMs: Int64,
                                    agentic: Bool,
                                    device: [String: Any],
                                    error: String) async {
        let endMs = TraceRecorder.nowMs()
        let summary = RunSummary(
            runId: runId,
            userMessage: prompt,
            finalStatus: "error",
            finalOutput: "",
            iteration: 0,
            startMs: startMs,
            endMs: endMs,
            extras: extras(modelFile: nil, agentic: agentic),
            device: device,
            error: error)
        await recorder.flushRunSummary(summary.toDictionary())
        await recorder.event(kind: "eval", name: "complete",
                              payload: ["status": "error",
                                        "error": error,
                                        "run_id": runId])
        await MainActor.run {
            EvalRunStatus.shared.transition(to: .failed, detail: error)
        }
    }

    private static func extras(modelFile: String?, agentic: Bool) -> [String: Any] {
        [
            "model_name": modelFile ?? "(default)",
            "agentic": agentic,
            "memory_isolated": true,
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
    /// On timeout, throws `ModelInitTimeout` so the caller can emit a
    /// dedicated error code in the trace.
    private static func withModelInitTimeout(seconds: UInt64,
                                             _ block: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await block() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw ModelInitTimeout(seconds: seconds)
            }
            // First completion wins; cancel the loser.
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

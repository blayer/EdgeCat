import Foundation
import Observation

// Observable state object the headless `EvalRunnerView` watches and
// `EvalEntryPoint` publishes to. Lifecycle: each launched eval gets a
// single `EvalRunStatus.shared`, which `EvalRunnerView` reads to render
// the status pill (Loading model → Running → Done / Error). Mirrors
// the role of Android's `EvalActivity` Compose state.

@MainActor
@Observable
public final class EvalRunStatus {
    public static let shared = EvalRunStatus()

    public enum Phase: Sendable, Equatable {
        case idle
        case loadingModel
        case running       // orchestrator phases (planner/execute/eval) are in flight
        case completed
        case failed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var prompt: String = ""
    public private(set) var runId: String = ""
    public private(set) var modelName: String = ""
    public private(set) var detail: String = ""

    public init() {}

    public func begin(prompt: String, runId: String, modelName: String) {
        self.prompt = prompt
        self.runId = runId
        self.modelName = modelName
        self.phase = .loadingModel
        self.detail = "Loading model…"
    }

    public func transition(to phase: Phase, detail: String? = nil) {
        self.phase = phase
        if let detail { self.detail = detail }
    }

    public func reset() {
        phase = .idle
        prompt = ""
        runId = ""
        modelName = ""
        detail = ""
    }
}

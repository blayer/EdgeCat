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
    /// User has tapped "Exit eval mode" on the EvalRunnerView. The
    /// outer scene observes this and switches back to `AppRouter` so
    /// the developer can inspect the post-eval state in the normal UI
    /// (the env-var-only check would hold us hostage on the headless
    /// surface for the rest of the process lifetime).
    public private(set) var exited: Bool = false

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

    /// Flip out of the headless eval surface. The outer scene watches
    /// this and re-renders `AppRouter` so the developer can poke around
    /// in the normal UI after a run completes (e.g. inspect chat state,
    /// settings, model picker). One-way for the process lifetime — a
    /// fresh launch with `EDGECAT_EVAL_MODE=1` resets it.
    public func requestExit() {
        exited = true
    }
}

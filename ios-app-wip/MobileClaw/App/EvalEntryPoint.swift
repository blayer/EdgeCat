import Foundation

// Mirrors android-app/.../eval/EvalActivity.kt — a URL-driven entry point
// that runs an orchestration loop with an in-memory store, captures a JSONL
// trace, and exits. iOS uses a custom URL scheme instead of an ADB intent:
//
//   xcrun simctl openurl <udid> \
//     "mobileclaw://eval?prompt=hello&model=gemma-4-E2B-it.litertlm&runId=test1"
//
// Trace lands at Documents/claw-traces/<runId>.jsonl. The app stays running
// after the eval finishes so simctl can pull the trace.

public enum EvalEntryPoint {
    @MainActor
    public static func handle(_ url: URL) {
        guard url.scheme == "mobileclaw", url.host == "eval" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let prompt = items.first(where: { $0.name == "prompt" })?.value ?? ""
        let modelFile = items.first(where: { $0.name == "model" })?.value
        let runId = items.first(where: { $0.name == "runId" })?.value ?? UUID().uuidString
        let agentic = items.first(where: { $0.name == "agentic" })?.value == "1"

        Task.detached { await run(prompt: prompt, modelFile: modelFile, runId: runId, agentic: agentic) }
    }

    private static func run(prompt: String, modelFile: String?, runId: String, agentic: Bool) async {
        let recorder = TraceRecorder(runId: runId)
        await recorder.event(kind: "eval", name: "start",
                             payload: ["prompt": prompt, "agentic": agentic ? "1" : "0"])

        guard !prompt.isEmpty, let modelURL = resolveModel(modelFile) else {
            await recorder.event(kind: "eval", name: "error",
                                  payload: ["message": "missing prompt or model"])
            return
        }

        let engine = LiteRtLmEngine()
        do {
            try await engine.initialize(config: LlmInitConfig(modelPath: modelURL, maxTokens: 1024))
            if agentic {
                let provider = LiteRtLmInferenceProvider(engine: engine)
                let tools = await SkillRegistry.defaultSet()
                let controller = await OrchestrationController(llm: provider, tools: tools, trace: recorder)
                let final = try await controller.handle(userMessage: prompt)
                await recorder.event(kind: "eval", name: "done",
                                      payload: ["mode": "agentic", "response": final])
            } else {
                var buffer = ""
                for try await token in engine.runInference(prompt: prompt) {
                    if token.isFinal { break }
                    buffer += token.text
                }
                await recorder.event(kind: "eval", name: "done",
                                      payload: ["mode": "chat", "response": buffer])
            }
        } catch {
            await recorder.event(kind: "eval", name: "error",
                                  payload: ["message": "\(error)"])
        }
    }

    private static func resolveModel(_ file: String?) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("Models", isDirectory: true)
        guard let dir else { return nil }
        if let file, !file.isEmpty {
            return dir.appendingPathComponent(file)
        }
        // Default: first .litertlm in the dir.
        let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents.first(where: { $0.pathExtension.lowercased() == "litertlm" })
    }
}

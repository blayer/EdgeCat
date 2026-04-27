import Foundation

// Phase A smoke test entry point. Activated when the launch env var
// MOBILECLAW_TEST_PROMPT is set. Loads the first .litertlm in Documents/Models/,
// sends the prompt, and logs streamed tokens to stdout — no UI tap required.
//
// Usage:
//   xcrun simctl launch --console <udid> com.mobileclawapp.app \
//     MOBILECLAW_TEST_PROMPT="What is the capital of France?"

enum SmokeTest {
    static func runIfRequested() {
        guard let prompt = ProcessInfo.processInfo.environment["MOBILECLAW_TEST_PROMPT"],
              !prompt.isEmpty else { return }
        Task.detached { await run(prompt: prompt) }
    }

    private static func run(prompt: String) async {
        print("[smoke] prompt: \(prompt)")
        guard let modelURL = firstModel() else {
            print("[smoke] FAIL: no .litertlm found in Documents/Models/")
            return
        }
        print("[smoke] model: \(modelURL.lastPathComponent)")
        let engine = LiteRtLmEngine()
        do {
            let initStart = Date()
            try await engine.initialize(config: LlmInitConfig(modelPath: modelURL, maxTokens: 1024))
            print(String(format: "[smoke] model loaded in %.2fs", Date().timeIntervalSince(initStart)))

            let inferStart = Date()
            var firstTokenAt: Date?
            var output = ""
            for try await token in engine.runInference(prompt: prompt) {
                if token.isFinal { break }
                if !token.text.isEmpty {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    output += token.text   // each chunk yields new tokens; append
                    print("[smoke] chunk: \(token.text.prefix(80))")
                }
            }
            let total = Date().timeIntervalSince(inferStart)
            let ttft = firstTokenAt.map { $0.timeIntervalSince(inferStart) } ?? -1
            print(String(format: "[smoke] DONE  ttft=%.2fs  total=%.2fs  chars=%d", ttft, total, output.count))
            print("[smoke] response:\n\(output)")
        } catch {
            print("[smoke] FAIL: \(error)")
        }
    }

    private static func firstModel() -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let dir = docs?.appendingPathComponent("Models", isDirectory: true)
        guard let dir,
              let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return contents.first(where: { $0.pathExtension.lowercased() == "litertlm" })
    }
}

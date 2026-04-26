import Foundation
import WebKit

// 1:1 functional port of android-app/.../runtime/skill/JsSkillRunner — loads
// a skill's index.html in a WKWebView and invokes a top-level async function
// with a single argument (the user's query / args), returns the result as
// a string. Each skill folder in Resources/skills/<skill>/scripts/index.html
// becomes a JsSkill instance that the SkillRegistry can dispatch.

@MainActor
public final class JsSkillRunner: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    public override init() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// Load the JS skill's index.html. The file URL must be a real on-disk
    /// path; WKWebView refuses bundled resources unless granted explicit
    /// read access to their containing directory.
    public func load(htmlURL: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.loadContinuation = cont
            let dir = htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: dir)
        }
    }

    /// Invoke a top-level async function in the loaded page with one JSON
    /// argument and return its result. Any thrown JS error is surfaced.
    public func invoke(function: String, jsonArg: String) async throws -> String {
        let script = """
        (async () => {
          try {
            const arg = \(jsonArg);
            const r = await \(function)(arg);
            return typeof r === 'string' ? r : JSON.stringify(r);
          } catch (e) { return 'Error: ' + (e?.message || e); }
        })()
        """
        let result = try await webView.evaluateJavaScript(script)
        if let str = result as? String { return str }
        return "\(result ?? "")"
    }

    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { @MainActor in
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: error)
            self.loadContinuation = nil
        }
    }
}

/// A Skill that delegates execution to a JS function defined in
/// Resources/skills/<name>/scripts/index.html. The skill name + the JS
/// function name + the args→JSON mapping are configured at construction.
@MainActor public final class JsSkill: Skill {
    nonisolated public let name: String
    nonisolated public let description: String
    /// JS function to call (e.g. `searchWeb`).
    public let jsFunction: String
    /// Bundle subdirectory under Resources/skills/.
    public let bundleDir: String

    public init(name: String, description: String, jsFunction: String, bundleDir: String) {
        self.name = name; self.description = description
        self.jsFunction = jsFunction; self.bundleDir = bundleDir
    }

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                        subdirectory: "skills/\(bundleDir)/scripts") else {
            return ToolExecutionResult(success: false, error: "index.html missing for \(name)")
        }
        let runner = JsSkillRunner()
        do {
            try await runner.load(htmlURL: url)
            // Pass the args dict as the JS function's single argument.
            // Most skills accept either a string (e.g., query) or an object.
            let jsonArg: String
            if let single = args["query"] ?? args["q"], args.count == 1 {
                jsonArg = "\"\(single.replacingOccurrences(of: "\"", with: "\\\""))\""
            } else if let data = try? JSONSerialization.data(withJSONObject: args),
                      let s = String(data: data, encoding: .utf8) {
                jsonArg = s
            } else {
                jsonArg = "{}"
            }
            let result = try await runner.invoke(function: jsFunction, jsonArg: jsonArg)
            return ToolExecutionResult(success: !result.hasPrefix("Error: "),
                                       output: result,
                                       error: result.hasPrefix("Error: ") ? result : nil)
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
    }
}

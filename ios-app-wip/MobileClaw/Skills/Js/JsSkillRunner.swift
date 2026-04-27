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

/// A Skill that delegates execution to the JS function defined in
/// `Resources/skills/<slug>/scripts/index.html`. Every JS skill in the
/// catalog (Android + iOS) follows the same entry-point contract:
///
///     window["ai_edge_gallery_get_result"] = async (data) => {
///         const json = JSON.parse(data);   // data is a JSON string
///         ...
///         return JSON.stringify(result);   // string or stringified object
///     };
///
/// We pass the agent's `args` dict serialized as a JSON string so the JS
/// side's `JSON.parse(data)` works without any per-skill argument shaping.
@MainActor public final class JsSkill: Skill {
    nonisolated public let name: String
    nonisolated public let description: String
    nonisolated public let instructions: String
    /// Bundle subdirectory under Resources/skills/.
    public let bundleDir: String
    /// True iff the skill's SKILL.md declares `require-secret: true`. The
    /// runner refuses to call the JS until the user has stored a secret in
    /// `SkillSecrets`.
    public let requireSecret: Bool
    public let requireSecretDescription: String

    public init(name: String, description: String, bundleDir: String,
                instructions: String = "",
                requireSecret: Bool = false,
                requireSecretDescription: String = "") {
        self.name = name; self.description = description
        self.bundleDir = bundleDir
        self.instructions = instructions
        self.requireSecret = requireSecret
        self.requireSecretDescription = requireSecretDescription
    }

    /// Convenience initializer for skills built from a parsed SKILL.md
    /// manifest. Used by `SkillRegistry.defaultSet()`.
    public convenience init(manifest: SkillManifest) {
        self.init(name: manifest.slug,
                  description: manifest.description,
                  bundleDir: manifest.slug,
                  instructions: manifest.instructions,
                  requireSecret: manifest.requireSecret,
                  requireSecretDescription: manifest.requireSecretDescription)
    }

    public func run(args: [String: String]) async -> ToolExecutionResult {
        if requireSecret, SkillSecrets.token(for: name) == nil {
            return ToolExecutionResult(success: false,
                                       error: "secret_required: \(requireSecretDescription.isEmpty ? name : requireSecretDescription)")
        }
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html",
                                        subdirectory: "skills/\(bundleDir)/scripts") else {
            return ToolExecutionResult(success: false, error: "index.html missing for \(name)")
        }
        let runner = JsSkillRunner()
        do {
            try await runner.load(htmlURL: url)
            // Build the JS-side `data` argument as a JSON string. The JS
            // entry function calls `JSON.parse(data)`, so we must hand it an
            // actual string (not a JS object literal). If the user passed a
            // bare `query` (single-arg shape), wrap it to match the
            // `{query: "..."}` convention skills expect.
            var payload = args
            if payload.isEmpty,
               let firstValue = args.values.first {
                payload = ["query": firstValue]
            }
            // Inject the per-skill secret so the JS can attach it to its
            // outbound request. Field name mirrors Android's convention.
            if requireSecret, let token = SkillSecrets.token(for: name) {
                payload["secret"] = token
            }
            let dataString: String = {
                guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                      let s = String(data: data, encoding: .utf8) else { return "{}" }
                return s
            }()
            // Escape the JSON-string-of-args into a JS string literal.
            let escaped = dataString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            let jsonArg = "\"\(escaped)\""
            let result = try await runner.invoke(function: "window[\"ai_edge_gallery_get_result\"]",
                                                  jsonArg: jsonArg)
            return ToolExecutionResult(success: !result.hasPrefix("Error: "),
                                       output: result,
                                       error: result.hasPrefix("Error: ") ? result : nil)
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
    }
}

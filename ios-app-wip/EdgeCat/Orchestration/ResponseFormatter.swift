import Foundation

// Mirrors android-app/.../orchestration/ResponseFormatter.kt — turns the raw
// step results into a single user-facing answer.
//
// Pipeline (Android parity):
//   1. Build raw output with per-step character budgets (single = 3500,
//      multi = 2800 for the last step + 400 for plumbing steps).
//   2. If the single-step output already carries iOS-renderable HTML
//      markup (table, ul, …), return it verbatim with isHtml=true so the
//      chat layer routes to its WebView fallback. iOS-specific carve-out
//      (Android only matches full HTML documents).
//   3. preprocess: parse JSON envelopes (`{"status":"succeeded", …}`)
//      into indented `key: value` text so the small model doesn't have
//      to decode raw JSON at generation time.
//   4. tryTrivialRender: if the data has exactly one non-bookkeeping
//      scalar value (or list of scalars), return it directly — saves an
//      LLM call when the skill already produced a user-ready answer
//      (calculator → "42", flashlight → "torch: on").
//   5. Otherwise call the LLM with a `<msg>…</msg>` few-shot prompt and
//      strip the wrapper / preambles from the response.

public struct ResponseFormatter {
    public let llm: LlmInferenceProvider
    public let policy: ThinkingPolicy

    public init(llm: LlmInferenceProvider, policy: ThinkingPolicy) {
        self.llm = llm
        self.policy = policy
    }

    public func format(userMessage: String,
                       plan: ExecutionPlan,
                       results: [String: StepResult]) async throws -> Formatted {
        let ordered = plan.steps.compactMap { results[$0.id] }
        if ordered.isEmpty {
            return Formatted(text: "(no result)", isHtml: false)
        }
        let completed = ordered.filter { $0.status == .completed && !$0.output.isEmpty }

        // iOS-only carve-out: a single skill output that already carries
        // renderable HTML markup goes through the chat WebView path. The
        // formatter LLM would just paraphrase the table away.
        if completed.count == 1, Self.containsHtmlMarkup(completed[0].output) {
            return Formatted(text: completed[0].output, isHtml: true)
        }

        let rawOutput = Self.buildRawOutput(plan: plan, results: results)
        let preprocessed = Self.preprocess(rawOutput)

        // Trivial-render shortcut only when we actually have content to
        // pass through. Empty raw → empty trivial would short-circuit
        // the LLM and surface "" to the user — bad for failure cases.
        if !rawOutput.isEmpty,
           let trivial = Self.tryTrivialRender(rawOutput),
           !trivial.isEmpty {
            return Formatted(text: trivial, isHtml: false)
        }

        do {
            let prompt = Self.buildPrompt(userMessage: userMessage, preprocessed: preprocessed)
            let complex = Self.isComplexOutput(preprocessed)
            let response = try await llm.generateResponse(
                prompt: prompt,
                enableThinking: policy.format(complexOutput: complex))
            let extracted = Self.extractMessage(response)
            if !extracted.isEmpty {
                return Formatted(text: extracted, isHtml: false)
            }
        } catch {
            // Fall through to preprocessed text.
        }
        let trimmedPreproc = preprocessed.trimmingCharacters(in: .whitespacesAndNewlines)
        return Formatted(text: trimmedPreproc.isEmpty ? "(no result)" : trimmedPreproc,
                         isHtml: false)
    }

    public struct Formatted: Sendable, Equatable {
        public let text: String
        public let isHtml: Bool
        public init(text: String, isHtml: Bool) {
            self.text = text; self.isHtml = isHtml
        }
    }

    // MARK: - Raw output assembly

    /// Builds the input the LLM (or trivial-renderer) sees. Mirrors
    /// `OrchestrationController.formatResultLikeAndroid` budgets.
    /// Falls back to including failed/skipped steps when no step
    /// succeeded so the LLM can still produce a user-facing failure
    /// summary instead of "(no result)".
    static func buildRawOutput(plan: ExecutionPlan,
                               results: [String: StepResult]) -> String {
        let completed = plan.steps.compactMap { step -> (PlanStep, StepResult)? in
            guard let r = results[step.id], r.status == .completed, !r.output.isEmpty
            else { return nil }
            return (step, r)
        }
        if completed.count == 1 {
            return String(completed[0].1.output.prefix(3500))
        }
        if !completed.isEmpty {
            let lastIdx = completed.count - 1
            let blocks = completed.enumerated().map { idx, pair -> String in
                let budget = idx == lastIdx ? 2800 : 400
                return "Step: \(pair.0.description)\nResult: \(String(pair.1.output.prefix(budget)))"
            }
            return String(blocks.joined(separator: "\n\n").prefix(3800))
        }
        // No success — assemble a status report from whatever steps
        // produced a result so the LLM can describe the failure.
        let fallback = plan.steps.compactMap { step -> String? in
            guard let r = results[step.id] else { return nil }
            let body = r.output.isEmpty ? (r.error ?? "(no output)") : r.output
            return "Step: \(step.description) [\(r.status.rawValue)]\nResult: \(String(body.prefix(800)))"
        }
        if fallback.isEmpty { return "" }
        return String(fallback.joined(separator: "\n\n").prefix(3800))
    }

    // MARK: - Preprocess (JSON → indented YAML-ish)

    /// Convert a JSON envelope (`{"status":"succeeded", …}`) into
    /// indented `key: value` text. Returns the input unchanged when it
    /// doesn't look like JSON or fails to parse.
    public static func preprocess(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return raw }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed])
        else { return raw }
        return render(parsed, indent: 0)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ node: Any, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        if let dict = node as? [String: Any] {
            if dict.isEmpty { return "{}" }
            // Preserve insertion order via JSONSerialization isn't possible —
            // sort to keep output deterministic.
            return dict.keys.sorted().map { key -> String in
                let value = dict[key] as Any
                if isScalar(value) {
                    return "\(pad)\(key): \(scalarString(value))"
                }
                if let arr = value as? [Any], arr.isEmpty { return "\(pad)\(key): []" }
                if let nested = value as? [String: Any], nested.isEmpty {
                    return "\(pad)\(key): {}"
                }
                return "\(pad)\(key):\n\(render(value, indent: indent + 1))"
            }.joined(separator: "\n")
        }
        if let arr = node as? [Any] {
            if arr.isEmpty { return "[]" }
            return arr.map { item -> String in
                if isScalar(item) { return "\(pad)- \(scalarString(item))" }
                let inner = render(item, indent: indent + 1)
                let lines = inner.split(separator: "\n", omittingEmptySubsequences: false)
                guard let firstLine = lines.first else { return "\(pad)- " }
                let rest = lines.dropFirst().joined(separator: "\n")
                let head = String(firstLine).drop { $0 == " " }
                if rest.isEmpty { return "\(pad)- \(head)" }
                return "\(pad)- \(head)\n\(rest)"
            }.joined(separator: "\n")
        }
        return "\(pad)\(scalarString(node))"
    }

    private static func isScalar(_ node: Any) -> Bool {
        if node is [String: Any] || node is [Any] { return false }
        return true
    }

    private static func scalarString(_ node: Any) -> String {
        if let s = node as? String { return s }
        if node is NSNull { return "null" }
        return String(describing: node)
    }

    // MARK: - Trivial render shortcut

    /// Single scalar / list-of-scalars → render directly without an LLM
    /// call. Returns nil when the output needs LLM formatting.
    public static func tryTrivialRender(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Plain scalar output (calculator, flashlight, etc.)
        if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
            if trimmed.count <= 200, !trimmed.contains("="),
               !trimmed.contains("Step:"), !trimmed.contains("\n") {
                return trimmed
            }
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]),
              let dict = parsed as? [String: Any]
        else { return nil }
        let bookkeeping: Set<String> = ["status", "error"]
        let payload = dict.filter { !bookkeeping.contains($0.key) }
        guard payload.count == 1, let only = payload.first else { return nil }
        if isScalar(only.value) {
            let s = scalarString(only.value)
            // search-web / search-photos / fetch-web-content all stuff a
            // multi-line block into a single `results` string. Treat that
            // as non-trivial so the LLM can summarize it.
            if s.contains("\n") || s.count > 200 { return nil }
            return s
        }
        if let arr = only.value as? [Any], !arr.isEmpty,
           arr.allSatisfy({ isScalar($0) }) {
            return arr.map { "• \(scalarString($0))" }.joined(separator: "\n")
        }
        return nil
    }

    // MARK: - LLM prompt + response post-processing

    /// Mirrors Android's `buildPrompt` verbatim — same few-shot examples
    /// and `<msg>…</msg>` wrapper so a single eval baseline applies.
    public static func buildPrompt(userMessage: String, preprocessed: String) -> String {
        """
        You rewrite raw tool output into a concise chat reply. Wrap your reply in <msg>...</msg>.

        Rules:
        - Use ONLY facts in "Raw result". Do not invent, guess, or add disclaimers.
        - Copy numbers, names, and error messages exactly, character for character.
        - No preamble ("Sure!", "Here's..."). No trailing chatter.
        - If the raw result has multiple "Step:" blocks, the LAST step usually holds the answer — focus on it. Earlier steps (e.g. location lookup) are context; do not describe them.
        - If the raw result has a "Page content from <url>" section, ANSWER the user's question using facts from that content. Cite ONLY the domain (e.g. "Source: accuweather.com") — never copy the full URL path, and never invent a path. Do NOT list the search result links.
        - If there is no fetched page content, fall back to a short bulleted list of the top 3 result titles, citing only the domain for each (e.g. "• Coroutines guide — kotlinlang.org"). Never copy full URL paths.

        Example — search with fetched content (ANSWER from content):
        User: weather in Paris tomorrow
        Raw result:
        Search results for: weather in Paris tomorrow

        1. Paris 14-day weather - weather.com
           https://weather.com/paris
           Updated hourly forecast for Paris, France.

        Page content from https://weather.com/paris

        Paris, France — Tomorrow: partly cloudy, high 18°C, low 11°C. Light winds 8 km/h. 20% chance of rain in the afternoon. Sunrise 6:42, sunset 20:15.
        Reply: <msg>Paris tomorrow: partly cloudy, high 18°C, low 11°C, light winds 8 km/h, 20% chance of afternoon rain. Sunrise 6:42, sunset 20:15.
        Source: weather.com</msg>

        Example — error:
        User: send sms to alice
        Raw result:
        status: failed
        error: Permission denied
        Reply: <msg>Couldn't send: SMS permission denied. Grant it in Settings and try again.</msg>

        Now format this one. Remember: no preamble, copy values verbatim, wrap in <msg>.

        User: \(userMessage)
        Raw result:
        \(preprocessed)
        Reply: <msg>
        """
    }

    /// Strip `<msg>...</msg>` and common preambles from an LLM response.
    public static func extractMessage(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: String
        if let regex = try? NSRegularExpression(
            pattern: "<msg>(.*?)(?:</msg>|$)",
            options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed)),
           match.numberOfRanges >= 2,
           let inner = Range(match.range(at: 1), in: trimmed) {
            body = String(trimmed[inner]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = trimmed
        }
        let preamble = #"(?i)^(sure[!,.]?|of course[!,.]?|here(?:'s| is)[^:\n]*:?|the (?:result|answer) is:?)\s*"#
        let stripped = body.replacingOccurrences(
            of: preamble, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic — Step-block count ≥ 2 OR length > 500 chars.
    public static func isComplexOutput(_ preprocessed: String) -> Bool {
        let stepCount = preprocessed
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("Step:") }.count
        return stepCount >= 2 || preprocessed.count > 500
    }

    // MARK: - HTML snippet detection (iOS-specific WebView path)

    /// Cheap heuristic — looks for an opening tag from the set we'd actually
    /// want to render (`<table>`, `<ul>`, `<ol>`, `<pre>`, `<code>`, `<a >`,
    /// `<div>`). Plain `<` in prose doesn't qualify.
    static func containsHtmlMarkup(_ text: String) -> Bool {
        let markers = ["<table", "<ul", "<ol", "<pre", "<code", "<a ", "<div", "<h1", "<h2", "<img"]
        let lower = text.lowercased()
        return markers.contains { lower.contains($0) }
    }
}

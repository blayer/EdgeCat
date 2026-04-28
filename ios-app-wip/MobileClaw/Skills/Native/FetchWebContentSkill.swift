import Foundation

// 1:1 port of android-app/.../DeviceSkills.fetchWebContent. GETs a URL
// and returns the response body as readable text. The HTML extractor
// strips boilerplate (script/style/nav/footer/header/aside/form) and
// preferentially keeps the <main>/<article> region, decodes common
// entities, drops nav-menu runs, and truncates to 4000 chars so the
// on-device LLM's context window doesn't blow up.

public final class FetchWebContentSkill: Skill, @unchecked Sendable {
    public var name: String { "fetch-web-content" }
    public var description: String {
        "GET a URL and return its body as readable text. arg: url. " +
        "HTML responses get boilerplate stripped + truncated to 4000 chars."
    }
    public init() {}

    private static let userAgent =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let raw = args["url"], let url = URL(string: raw),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            return ToolExecutionResult(success: false, error: "invalid 'url' argument")
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.timeoutInterval = 15
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,*/*",
                             forHTTPHeaderField: "Accept")
            // 10s connect (NSURLConnection caps individual phases via the
            // overall `timeoutInterval`; URLSession gives us one knob).
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ToolExecutionResult(success: false, error: "no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                return ToolExecutionResult(success: false,
                                           error: "HTTP \(http.statusCode)")
            }
            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            let rawBody = String(data: data, encoding: .utf8) ?? ""

            let body = contentType.lowercased().contains("html")
                ? Self.extractTextFromHtml(rawBody)
                : rawBody
            let truncated = body.count > 4000
                ? String(body.prefix(4000)) + "\n...[truncated]"
                : body

            let payload: [String: Any] = [
                "status": "succeeded",
                "url": url.absoluteString,
                "content_type": contentType,
                "content": truncated,
                "content_length": body.count,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? truncated
            return ToolExecutionResult(success: true, output: json)
        } catch {
            return ToolExecutionResult(success: false,
                                       error: "\(error.localizedDescription)")
        }
    }

    // MARK: - HTML extraction (mirrors Android's extractTextFromHtml)

    /// Best-effort HTML → text conversion tuned for on-device LLM
    /// consumption. Each step deliberately uses regex over a real DOM
    /// parser because a) we already accept truncation and b) iOS
    /// doesn't ship a permissive HTML parser without WebKit.
    static func extractTextFromHtml(_ html: String) -> String {
        // 1. Drop script/style/nav/footer/header/aside/form blocks —
        //    pure boilerplate that bloats context for no signal.
        var text = html.replacingOccurrences(
            of: #"<(script|style|nav|footer|header|aside|form)[^>]*>[\s\S]*?</\1>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive])

        // 2. Prefer <main> / <article> content if present — pages that
        //    use semantic markup have already told us where the meat is.
        if let mainRange = text.range(
            of: #"<(main|article)\b[^>]*>([\s\S]*?)</\1>"#,
            options: [.regularExpression, .caseInsensitive]) {
            // Capture group 2 is the inner content. NSRegularExpression
            // doesn't directly expose it from String.range, so re-run.
            if let re = try? NSRegularExpression(
                pattern: #"<(main|article)\b[^>]*>([\s\S]*?)</\1>"#,
                options: .caseInsensitive),
               let m = re.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)),
               let inner = Range(m.range(at: 2), in: text) {
                text = String(text[inner])
            } else {
                text = String(text[mainRange])  // fall back to the whole match
            }
        }

        // 3. Convert block-level tags + table rows to newlines so
        //    content doesn't smash together into a single paragraph.
        text = text.replacingOccurrences(
            of: #"<(br|p|div|li|h[1-6]|tr|section)[^>]*/?>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive])

        // 4. Convert <td>/<th> to tabs so table rows stay scannable.
        text = text.replacingOccurrences(
            of: #"<(td|th)[^>]*/?>"#,
            with: "\t",
            options: [.regularExpression, .caseInsensitive])

        // 5. Strip remaining tags.
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ",
                                          options: .regularExpression)

        // 6. Decode the common HTML entities. Anything more exotic stays
        //    as-is — better visible noise than a missing &mdash;.
        text = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // 7. Collapse whitespace per line; keep paragraph boundaries.
        let collapsed = text
            .components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]+"#, with: " ",
                                            options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // 8. Drop nav-menu runs: 3+ consecutive short, non-sentence,
        //    non-data lines are almost always a menu strip; isolated
        //    short lines in prose should stay. Mirrors Android's filter.
        return removeNavRuns(collapsed)
    }

    /// Removes 3+ consecutive nav-like short lines while preserving
    /// short data lines (temperatures, percentages, sentence-ending
    /// punctuation) anywhere they appear.
    static func removeNavRuns(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        // Pre-compute the nav-likeness of each line so the runs check is
        // a simple windowed scan.
        let isNav = lines.map(isNavLike(_:))
        var keep = Array(repeating: true, count: lines.count)
        var i = 0
        while i < lines.count {
            if isNav[i] {
                var j = i
                while j < lines.count && isNav[j] { j += 1 }
                let runLen = j - i
                if runLen >= 3 {
                    for k in i..<j { keep[k] = false }
                }
                i = j
            } else {
                i += 1
            }
        }
        return zip(lines, keep)
            .compactMap { $0.1 ? $0.0 : nil }
            .joined(separator: "\n")
    }

    static func isNavLike(_ line: String) -> Bool {
        if line.count >= 50 { return false }
        // Sentence-ending punctuation in a non-tiny line → real prose.
        if line.contains(where: { ".?!:".contains($0) }) && line.count >= 20 {
            return false
        }
        // Short lines with weather/temperature/measurement signals are
        // data, not nav — keep them.
        let dataPattern = #"[-+]?\d+\s*(?:°|°c|°f|%|km/h|mph|mm|in)\b"#
        if line.range(of: dataPattern,
                       options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        return true
    }
}

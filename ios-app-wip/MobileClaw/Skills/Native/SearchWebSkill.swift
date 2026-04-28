import Foundation

// 1:1 port of android-app/.../assets/skills/search-web/scripts/index.html
// (which Android runs through its JS-skill WebView). Scrapes Google
// search HTML for the top 8 results, returning title + url + snippet
// per result. The Mobile Chrome User-Agent is what makes Google return
// the parseable mobile HTML layout — desktop UAs return JS-shell pages
// the regex/DOM parser can't read.
//
// Output is structured JSON: query, result_count, results (formatted
// text). 3000-char cap matches Android so the agentic-mode planner
// prompt can fit a follow-up step.

public final class SearchWebSkill: Skill, @unchecked Sendable {
    public var name: String { "search-web" }
    public var description: String {
        "Search the web (Google). arg: query. Returns the top 8 results with " +
        "title, URL, and snippet."
    }
    public init() {}

    private static let userAgent =
        "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let raw = (args["query"] ?? args["q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let escaped = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(escaped)&hl=en&num=8") else {
            return ToolExecutionResult(success: false, error: "missing 'query' argument")
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return ToolExecutionResult(success: false,
                                           error: "Search failed: HTTP \(http.statusCode)")
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            let results = Self.parseGoogleResults(html)
            if results.isEmpty {
                return ToolExecutionResult(success: false,
                                           error: "No search results found for: \(raw)")
            }
            let formatted = Self.format(results: results)
            let payload: [String: Any] = [
                "status": "succeeded",
                "query": raw,
                "result_count": results.count,
                "results": formatted,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? formatted
            return ToolExecutionResult(success: true, output: json)
        } catch {
            return ToolExecutionResult(success: false, error: "\(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    struct WebSearchResult: Equatable {
        let title: String
        let url: String
        let snippet: String
    }

    /// Pulls result triplets from Google's mobile HTML. Mirrors the JS
    /// skill's strategy: try the structured `<a href><h3>title</h3>`
    /// pattern first; fall back to a looser regex on the raw HTML so we
    /// at least return something when Google rejiggers their markup.
    static func parseGoogleResults(_ html: String) -> [WebSearchResult] {
        let primary = parseLinkH3(html)
        if !primary.isEmpty { return primary }
        return parseLooseRegex(html)
    }

    private static func parseLinkH3(_ html: String) -> [WebSearchResult] {
        // <a href="https://…"> … <h3 …>Title</h3> … </a>
        // Google wraps the title in an <h3> nested in an <a>.
        let pattern = #"<a[^>]*href="(https?://[^"]+)"[^>]*>[\s\S]*?<h3[^>]*>([\s\S]*?)</h3>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html,
                                  range: NSRange(location: 0, length: ns.length))
        var out: [WebSearchResult] = []
        for m in matches {
            let url = ns.substring(with: m.range(at: 1))
            let titleHtml = ns.substring(with: m.range(at: 2))
            let title = stripTags(titleHtml).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  !url.contains("google.com"),
                  !url.contains("/search?") else { continue }
            // Look for a snippet near this match — common Google
            // wrappers: <div class="VwiC3b">, <span class="aCOpRe">,
            // <div data-sncf=...>. Skip if not found.
            let snippet = findSnippetNear(html: ns, after: m.range(at: 2).upperBound)
            out.append(WebSearchResult(title: title, url: url, snippet: snippet))
            if out.count >= 8 { break }
        }
        return out
    }

    /// Backstop when the structured selector misses (e.g. Google ships
    /// a markup variant we don't recognize). Same regex the Android JS
    /// fallback uses.
    private static func parseLooseRegex(_ html: String) -> [WebSearchResult] {
        let pattern = #"<a[^>]*href="(https?://[^"]+)"[^>]*>[\s\S]*?<h3[^>]*>([\s\S]*?)</h3>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html,
                                  range: NSRange(location: 0, length: ns.length))
        var out: [WebSearchResult] = []
        for m in matches {
            let url = ns.substring(with: m.range(at: 1))
            let titleHtml = ns.substring(with: m.range(at: 2))
            let title = stripTags(titleHtml).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !url.contains("google.com") else { continue }
            out.append(WebSearchResult(title: title, url: url, snippet: ""))
            if out.count >= 8 { break }
        }
        return out
    }

    private static func findSnippetNear(html: NSString, after offset: Int) -> String {
        let remaining = NSRange(location: offset,
                                length: max(0, min(2000, html.length - offset)))
        // Try Google's snippet wrappers in order of how often they appear.
        for pattern in [
            #"<div class="VwiC3b[^"]*"[^>]*>([\s\S]*?)</div>"#,
            #"<span class="aCOpRe[^"]*"[^>]*>([\s\S]*?)</span>"#,
            #"<div data-sncf[^>]*>([\s\S]*?)</div>"#,
        ] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: html as String, range: remaining) {
                let snippetHtml = html.substring(with: m.range(at: 1))
                return stripTags(snippetHtml).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    static func format(results: [WebSearchResult]) -> String {
        var formatted = ""
        for (i, r) in results.enumerated() {
            formatted += "\(i + 1). \(r.title)\n"
            formatted += "   \(r.url)\n"
            if !r.snippet.isEmpty { formatted += "   \(r.snippet)\n" }
            formatted += "\n"
        }
        if formatted.count > 3000 {
            formatted = String(formatted.prefix(3000)) + "\n...[truncated]"
        }
        return formatted.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

// Search the web by scraping DuckDuckGo's HTML endpoint
// (https://html.duckduckgo.com/html/?q=…). Google's mobile search
// detects non-JS clients and returns a redirect-shell page that we
// can't parse from a URLSession-based skill — Android's JS skill
// gets away with scraping Google because it runs inside a WKWebView
// with real `fetch()` + DOMParser. From this Swift Skill we don't
// have a JS engine, so DDG's `/html/` endpoint (specifically
// designed for non-JS clients) is the only reliable option.
//
// Output shape mirrors android-app's JS skill: structured JSON with
// query, result_count, and a formatted multi-line `results` field
// (title + URL + snippet per item, capped at 3000 chars).

public final class SearchWebSkill: Skill, @unchecked Sendable {
    public var name: String { "search-web" }
    public var description: String {
        "Search the web (DuckDuckGo). arg: query. Returns the top 8 results " +
        "with title, URL, and snippet. " +
        "For ANSWERING a question (weather, news, facts) chain with " +
        "fetch-web-content on the top result's URL — the search output " +
        "alone is just a link list, not the answer."
    }
    public init() {}

    private static let userAgent =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let raw = (args["query"] ?? args["q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty,
              let escaped = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(escaped)") else {
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
            let results = Self.parseDuckDuckGoResults(html)
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

    /// DDG wraps each result in `<a class="result__a">` with the title as
    /// inner text, and the snippet in a sibling `<a class="result__snippet">`
    /// or `<div class="result__snippet">`. URLs go through DDG's
    /// `/l/?uddg=<url-encoded>` redirect — we unwrap them so the agent
    /// gets clickable destination URLs.
    static func parseDuckDuckGoResults(_ html: String) -> [WebSearchResult] {
        let titlePattern =
            #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        guard let titleRe = try? NSRegularExpression(pattern: titlePattern) else {
            return []
        }
        let snippetPattern =
            #"class="result__snippet"[^>]*>([\s\S]*?)</a>"#
        let snippetRe = try? NSRegularExpression(pattern: snippetPattern)

        let ns = html as NSString
        let titleMatches = titleRe.matches(in: html,
                                            range: NSRange(location: 0, length: ns.length))
        let snippetMatches: [String]
        if let snippetRe {
            snippetMatches = snippetRe
                .matches(in: html, range: NSRange(location: 0, length: ns.length))
                .map { stripTags(ns.substring(with: $0.range(at: 1)))
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
        } else {
            snippetMatches = []
        }

        var out: [WebSearchResult] = []
        for (i, m) in titleMatches.enumerated() where out.count < 8 {
            let rawUrl = ns.substring(with: m.range(at: 1))
            let titleHtml = ns.substring(with: m.range(at: 2))
            let title = stripTags(titleHtml).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let url = unwrapDuckDuckGoRedirect(rawUrl)
            let snippet = i < snippetMatches.count ? snippetMatches[i] : ""
            out.append(WebSearchResult(title: title, url: url, snippet: snippet))
        }
        return out
    }

    /// DDG redirects look like `//duckduckgo.com/l/?uddg=<url-encoded>&rut=…`.
    /// Pull the `uddg` param and percent-decode it. Falls back to the
    /// raw URL when the format isn't recognized so we don't hide
    /// non-redirect results.
    static func unwrapDuckDuckGoRedirect(_ raw: String) -> String {
        // Build absolute URL so URLComponents can parse the query.
        var s = raw
        if s.hasPrefix("//") { s = "https:" + s }
        guard let comps = URLComponents(string: s),
              let item = comps.queryItems?.first(where: { $0.name == "uddg" }),
              let value = item.value?.removingPercentEncoding else {
            return raw
        }
        return value
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

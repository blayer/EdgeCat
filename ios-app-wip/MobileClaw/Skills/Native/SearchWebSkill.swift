import Foundation

// 1:1 functional port of android-app/assets/skills/search-web — DuckDuckGo
// HTML endpoint scrape, no API key needed. Returns top results as text.

public final class SearchWebSkill: Skill, @unchecked Sendable {
    public var name: String { "search-web" }
    public var description: String { "Search the web and return top results. arg: query" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let q = args["query"] ?? args["q"], !q.isEmpty,
              let escaped = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://duckduckgo.com/html/?q=\(escaped)") else {
            return ToolExecutionResult(success: false, error: "missing 'query' argument")
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (compatible; Mobile-Claw/0.1)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""
            return ToolExecutionResult(success: true, output: parseResults(html))
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
    }

    private func parseResults(_ html: String) -> String {
        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>([^<]+)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(5)
        return matches.enumerated().map { idx, m in
            let url = ns.substring(with: m.range(at: 1))
            let title = ns.substring(with: m.range(at: 2))
            return "\(idx + 1). \(title) — \(url)"
        }.joined(separator: "\n")
    }
}

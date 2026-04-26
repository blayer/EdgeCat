import Foundation

// 1:1 functional port of android-app/assets/skills/fetch-web-content.
// Fetches a URL and returns the response body as text (strips obvious HTML
// boilerplate so the LLM context stays useful).

public final class FetchWebContentSkill: Skill, @unchecked Sendable {
    public var name: String { "fetch-web-content" }
    public var description: String { "GET a URL and return its text body. arg: url" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let raw = args["url"], let url = URL(string: raw), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            return ToolExecutionResult(success: false, error: "invalid 'url' argument")
        }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Mozilla/5.0 (compatible; Mobile-Claw/0.1)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                return ToolExecutionResult(success: false, error: "HTTP \(code)")
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return ToolExecutionResult(success: true, output: stripHtml(text))
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
    }

    private func stripHtml(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\\n+\\s*", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

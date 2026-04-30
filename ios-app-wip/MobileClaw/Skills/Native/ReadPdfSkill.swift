import Foundation
import PDFKit

// PDFKit text + metadata extraction. iOS-platform-unique: Android has
// no system PDF text extractor — third-party libs only. iOS bundles
// PDFKit (Documents app, Preview, etc. all use it) so we get accurate
// text extraction including kerned glyph runs and embedded fonts for
// free.
//
// args:
//   path        — absolute file path to a .pdf on disk. Required.
//   max_pages   — cap pages parsed (default 50, max 200). Lets the
//                 planner trim a 500-page report without blowing out
//                 the LLM context budget.
//   max_chars   — cap returned text length (default 4000, max 20000).
//                 Same rationale.
//
// Output JSON: { status, path, page_count, parsed_pages, text,
//                truncated_text: bool, title, author }

public final class ReadPdfSkill: Skill, @unchecked Sendable {
    public var name: String { "read-pdf" }
    public var description: String {
        "Extract text and metadata from a PDF file on disk. " +
        "args: path=<file path>, max_pages=<N, default 50>, " +
        "max_chars=<N, default 4000>"
    }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        guard let path = args["path"], !path.isEmpty else {
            return ToolExecutionResult(success: false, error: "missing 'path' argument")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ToolExecutionResult(success: false, error: "file not found: \(path)")
        }
        guard let document = PDFDocument(url: url) else {
            return ToolExecutionResult(success: false,
                                       error: "couldn't open PDF (corrupt or password-protected): \(path)")
        }
        let maxPages = max(1, min(args["max_pages"].flatMap(Int.init) ?? 50, 200))
        let maxChars = max(100, min(args["max_chars"].flatMap(Int.init) ?? 4000, 20000))

        let parsedPages = min(document.pageCount, maxPages)
        var collected = ""
        for i in 0..<parsedPages {
            guard let page = document.page(at: i),
                  let pageText = page.string else { continue }
            collected += pageText
            collected += "\n"
            if collected.count >= maxChars { break }
        }
        let truncated = collected.count >= maxChars
        let text = String(collected.prefix(maxChars))

        let attrs = document.documentAttributes ?? [:]
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""

        let payload: [String: Any] = [
            "status": "succeeded",
            "path": path,
            "page_count": document.pageCount,
            "parsed_pages": parsedPages,
            "text": text,
            "truncated_text": truncated,
            "title": title,
            "author": author,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ToolExecutionResult(success: true, output: json)
    }
}

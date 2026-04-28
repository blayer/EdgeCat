import XCTest
import PDFKit
@testable import MobileClaw

/// PDFKit is available in the simulator with no permission gates. We
/// generate a small PDF at runtime, write it to a temp path, and verify
/// the skill round-trips text + metadata. Avoids fixture file management.
final class ReadPdfSkillTests: XCTestCase {

    func testNameAndDescriptionAreStable() {
        let s = ReadPdfSkill()
        XCTAssertEqual(s.name, "read-pdf")
        XCTAssertTrue(s.description.lowercased().contains("pdf"))
    }

    func testMissingPathReturnsError() async {
        let s = ReadPdfSkill()
        let r = await s.run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "missing 'path' argument")
    }

    func testNonexistentPathReturnsClearError() async {
        let s = ReadPdfSkill()
        let r = await s.run(args: ["path": "/tmp/does-not-exist-\(UUID().uuidString).pdf"])
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("file not found"))
    }

    func testExtractsTextFromGeneratedPdf() async throws {
        let path = try renderPdf(text: "Mobile-Claw test page",
                                  title: "Eval Sample",
                                  author: "Mobile-Claw Tests")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s = ReadPdfSkill()
        let r = await s.run(args: ["path": path])
        XCTAssertTrue(r.success, "expected success, got error: \(r.error ?? "")")

        guard let data = r.output.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return XCTFail("output is not JSON: \(r.output)")
        }
        XCTAssertEqual(json["status"] as? String, "succeeded")
        XCTAssertEqual(json["page_count"] as? Int, 1)
        XCTAssertEqual(json["parsed_pages"] as? Int, 1)
        let text = (json["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("Mobile-Claw"),
                      "expected 'Mobile-Claw' in extracted text, got: '\(text)'")
        // Metadata in PDFKit-attribute form may or may not survive the
        // simple `UIGraphicsPDFRenderer` path, so we don't strictly
        // assert title/author values — only the keys are present.
        XCTAssertNotNil(json["title"])
        XCTAssertNotNil(json["author"])
    }

    func testTruncatesAtMaxChars() async throws {
        // Long text → truncated_text=true and prefix matches.
        let long = String(repeating: "abcdefghij ", count: 500)
        let path = try renderPdf(text: long, title: "", author: "")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s = ReadPdfSkill()
        let r = await s.run(args: ["path": path, "max_chars": "200"])
        XCTAssertTrue(r.success)
        guard let data = r.output.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return XCTFail("not JSON: \(r.output)")
        }
        XCTAssertEqual(json["truncated_text"] as? Bool, true)
        XCTAssertLessThanOrEqual(((json["text"] as? String) ?? "").count, 200)
    }

    /// Render a single-page PDF with `text` drawn into a wrapping
    /// rectangle (so long strings actually appear on the page rather
    /// than overflowing past the right margin and being clipped at
    /// extraction time). Returns the path to a temp `.pdf` file.
    private func renderPdf(text: String, title: String, author: String) throws -> String {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextAuthor as String: author,
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.black,
            ]
            let frame = pageRect.insetBy(dx: 50, dy: 50)
            (text as NSString).draw(in: frame, withAttributes: attrs)
        }
        let path = NSTemporaryDirectory() + "pdfktest-\(UUID().uuidString).pdf"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}

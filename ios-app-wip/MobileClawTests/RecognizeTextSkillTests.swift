import XCTest
import UIKit
@testable import MobileClaw

/// Vision text recognition is on-device and works in the simulator. We
/// generate a `UIImage` at runtime with known text drawn on it, write
/// it to a temp file, and verify the OCR output contains the expected
/// substring. Avoids fixture file management while still proving the
/// skill end-to-end on sim.
final class RecognizeTextSkillTests: XCTestCase {

    func testNameAndDescriptionAreStable() {
        let s = RecognizeTextSkill()
        XCTAssertEqual(s.name, "recognize-text")
        XCTAssertTrue(s.description.lowercased().contains("ocr") ||
                       s.description.lowercased().contains("text"))
    }

    func testMissingPathAndPhotoIdReturnsError() async {
        let s = RecognizeTextSkill()
        let r = await s.run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "missing 'path' or 'photo_id' argument")
    }

    func testNonexistentPathReportsLoadError() async {
        let s = RecognizeTextSkill()
        let r = await s.run(args: ["path": "/tmp/does-not-exist-\(UUID().uuidString).png"])
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("couldn't load image"))
    }

    func testRecognizesSimpleText() async throws {
        let path = try renderImage(text: "Mobile-Claw", size: CGSize(width: 600, height: 200))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s = RecognizeTextSkill()
        let r = await s.run(args: ["path": path])
        XCTAssertTrue(r.success, "expected success, got error: \(r.error ?? "")")

        guard let data = r.output.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return XCTFail("output is not JSON: \(r.output)")
        }
        XCTAssertEqual(json["status"] as? String, "succeeded")
        let text = (json["text"] as? String) ?? ""
        XCTAssertTrue(text.lowercased().contains("mobile") ||
                       text.lowercased().contains("claw"),
                      "expected 'Mobile-Claw' in OCR output, got: '\(text)'")
        XCTAssertGreaterThan(json["observation_count"] as? Int ?? 0, 0)
    }

    /// Renders `text` onto a white background and writes a PNG to the
    /// temp dir. Returns the file path.
    private func renderImage(text: String, size: CGSize) throws -> String {
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 80, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let line = s.size()
            s.draw(at: CGPoint(x: (size.width - line.width) / 2,
                               y: (size.height - line.height) / 2))
        }
        guard let png = img.pngData() else {
            throw NSError(domain: "OCRTests", code: 0,
                           userInfo: [NSLocalizedDescriptionKey: "no PNG"])
        }
        let path = NSTemporaryDirectory() + "ocrtest-\(UUID().uuidString).png"
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }
}

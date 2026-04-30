import XCTest
@testable import EdgeCat

/// `LPMetadataProvider` requires a network round-trip and is gated by
/// the system extension that owns the metadata cache. We don't exercise
/// real fetches in unit tests — too flaky on CI / sim without internet.
/// These tests focus on the deterministic surface: arg validation, URL
/// scheme allowlist.
final class PreviewUrlSkillTests: XCTestCase {

    func testNameAndDescriptionAreStable() {
        let s = PreviewUrlSkill()
        XCTAssertEqual(s.name, "preview-url")
        XCTAssertTrue(s.description.lowercased().contains("preview"))
    }

    func testMissingUrlReturnsError() async {
        let s = PreviewUrlSkill()
        let r = await s.run(args: [:])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "missing 'url' argument")
    }

    func testEmptyUrlReturnsError() async {
        let s = PreviewUrlSkill()
        let r = await s.run(args: ["url": ""])
        XCTAssertFalse(r.success)
        XCTAssertEqual(r.error, "missing 'url' argument")
    }

    func testNonHttpSchemeRejected() async {
        let s = PreviewUrlSkill()
        for scheme in ["file:///tmp/x", "ftp://example.com", "javascript:alert(1)"] {
            let r = await s.run(args: ["url": scheme])
            XCTAssertFalse(r.success, "expected rejection for \(scheme)")
            XCTAssertTrue((r.error ?? "").contains("http"),
                          "expected 'http' in error for \(scheme), got: \(r.error ?? "")")
        }
    }

    func testMalformedUrlRejected() async {
        let s = PreviewUrlSkill()
        let r = await s.run(args: ["url": "not a url at all"])
        XCTAssertFalse(r.success)
        // Either "url must be http(s)" (URL parses with no scheme) or a
        // metadata-fetch failure — both are acceptable rejections.
        XCTAssertNotNil(r.error)
    }
}

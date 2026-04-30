import XCTest
@testable import EdgeCat

final class PromptTemplatesTests: XCTestCase {

    func testLoadsBundledTemplates() {
        let templates = PromptTemplates.load()
        XCTAssertFalse(templates.isEmpty,
                       "prompt_templates.json should ship with the app")
    }

    func testTemplatesAreNonEmptyStrings() {
        for t in PromptTemplates.load() {
            XCTAssertFalse(t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

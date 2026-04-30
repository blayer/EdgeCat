import XCTest
@testable import EdgeCat

final class SkillManifestTests: XCTestCase {

    func testParsesMinimalFrontmatter() throws {
        let md = """
        ---
        name: query-wikipedia
        description: Query summary from Wikipedia for a given topic.
        ---

        # Query Wiki

        ## Instructions

        Call the run_js tool with topic + lang.
        """
        let m = try XCTUnwrap(SkillManifestParser.parse(contents: md,
                                                        slug: "query-wikipedia",
                                                        hasJsScripts: true))
        XCTAssertEqual(m.slug, "query-wikipedia")
        XCTAssertEqual(m.name, "query-wikipedia")
        XCTAssertEqual(m.description, "Query summary from Wikipedia for a given topic.")
        XCTAssertFalse(m.requireSecret)
        XCTAssertEqual(m.requireSecretDescription, "")
        XCTAssertTrue(m.instructions.contains("Call the run_js tool"))
        XCTAssertTrue(m.hasJsScripts)
    }

    func testParsesRequireSecretAndQuotedValues() throws {
        let md = """
        ---
        name: brave-search
        description: "Search the web with Brave."
        require-secret: true
        require-secret-description: "Get a token at brave.com/search/api."
        homepage: "https://search.brave.com"
        ---

        ## Instructions

        Body here.
        """
        let m = try XCTUnwrap(SkillManifestParser.parse(contents: md,
                                                        slug: "brave-search",
                                                        hasJsScripts: false))
        XCTAssertTrue(m.requireSecret)
        XCTAssertEqual(m.requireSecretDescription, "Get a token at brave.com/search/api.")
        XCTAssertEqual(m.homepage, "https://search.brave.com")
        XCTAssertEqual(m.description, "Search the web with Brave.")
        XCTAssertFalse(m.hasJsScripts)
    }

    func testFallsBackToSlugWhenNameMissing() throws {
        let md = """
        ---
        description: A skill without an explicit name.
        ---
        """
        let m = try XCTUnwrap(SkillManifestParser.parse(contents: md,
                                                        slug: "fallback-slug",
                                                        hasJsScripts: false))
        XCTAssertEqual(m.name, "fallback-slug",
                       "Missing `name:` should fall back to the directory slug")
    }

    func testInstructionsBodyEmptyWhenNoSection() throws {
        let md = """
        ---
        name: x
        description: y
        ---

        # Just a heading

        Some prose without an Instructions section.
        """
        let m = try XCTUnwrap(SkillManifestParser.parse(contents: md,
                                                        slug: "x",
                                                        hasJsScripts: false))
        // No `## Instructions` block: the parser keeps the whole body as
        // instructions, so the planner still sees something useful.
        XCTAssertTrue(m.instructions.contains("Some prose without an Instructions section."))
    }

    func testRejectsNonFrontmatterDocuments() {
        XCTAssertNil(SkillManifestParser.parse(contents: "Just plain text.",
                                                slug: "x", hasJsScripts: false))
        XCTAssertNil(SkillManifestParser.parse(contents: "",
                                                slug: "x", hasJsScripts: false))
    }

    func testBundleScanFindsSkillsAndFlagsJs() {
        let manifests = SkillBundle.scanResources()
        XCTAssertFalse(manifests.isEmpty,
                       "Resources/skills/ should ship at least one SKILL.md")
        let slugs = Set(manifests.map(\.slug))
        XCTAssertTrue(slugs.contains("query-wikipedia"),
                      "query-wikipedia is the canonical JS skill — must be discoverable")
        XCTAssertTrue(slugs.contains("search-web"),
                      "search-web ships JS scripts in iOS bundle")
        if let qw = manifests.first(where: { $0.slug == "query-wikipedia" }) {
            XCTAssertTrue(qw.hasJsScripts,
                          "query-wikipedia ships index.html, scanner must mark hasJsScripts")
        }
    }
}

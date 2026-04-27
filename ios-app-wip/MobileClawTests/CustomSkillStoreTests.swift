import XCTest
@testable import MobileClaw

@MainActor
final class CustomSkillStoreTests: XCTestCase {

    /// Each test runs against its own slug to avoid leaking state across
    /// runs — the Documents dir is shared with the host app simulator.
    private var testSlug: String!

    override func setUp() {
        super.setUp()
        testSlug = "test-\(UUID().uuidString.prefix(6).lowercased())"
    }

    override func tearDown() {
        try? CustomSkillStore.delete(slug: testSlug)
        super.tearDown()
    }

    func testCreateAndScan() throws {
        try CustomSkillStore.create(CustomSkillDraft(
            slug: testSlug,
            description: "test fixture skill",
            instructions: "Run me with no args.",
            jsBody: """
            window["ai_edge_gallery_get_result"] = async () => "hi";
            """))
        let manifests = SkillBundle.scanCustom()
        let mine = try XCTUnwrap(manifests.first { $0.slug == testSlug })
        XCTAssertEqual(mine.source, .custom)
        XCTAssertEqual(mine.description, "test fixture skill")
        XCTAssertTrue(mine.instructions.contains("Run me with no args."))
        XCTAssertTrue(mine.hasJsScripts,
                      "Custom skill with non-empty jsBody must have hasJsScripts=true")
        XCTAssertFalse(mine.requireSecret)
    }

    func testCreateRefusesDuplicateSlug() throws {
        try CustomSkillStore.create(CustomSkillDraft(
            slug: testSlug, description: "x", instructions: "y"))
        XCTAssertThrowsError(try CustomSkillStore.create(CustomSkillDraft(
            slug: testSlug, description: "z", instructions: "w")))
    }

    func testCreateRejectsInvalidSlug() {
        for bad in ["", "a", "no_underscores", "Spaces Bad", "Caps", "way-too-long-\(String(repeating: "x", count: 60))", "weird?chars!"] {
            XCTAssertThrowsError(try CustomSkillStore.create(CustomSkillDraft(
                slug: bad, description: "d", instructions: "i")),
                "expected slug \"\(bad)\" to be rejected")
        }
    }

    func testUpdateMetadataPersists() throws {
        try CustomSkillStore.create(CustomSkillDraft(
            slug: testSlug, description: "original", instructions: "first"))
        try CustomSkillStore.updateMetadata(CustomSkillDraft(
            slug: testSlug, description: "updated", instructions: "second",
            requireSecret: true, requireSecretDescription: "Need a token."))
        let mine = try XCTUnwrap(SkillBundle.scanCustom().first { $0.slug == testSlug })
        XCTAssertEqual(mine.description, "updated")
        XCTAssertTrue(mine.instructions.contains("second"))
        XCTAssertTrue(mine.requireSecret)
        XCTAssertEqual(mine.requireSecretDescription, "Need a token.")
    }

    func testUpdateJsBodyRoundTrip() throws {
        try CustomSkillStore.create(CustomSkillDraft(
            slug: testSlug, description: "x", instructions: "y",
            jsBody: """
            window["ai_edge_gallery_get_result"] = async () => "v1";
            """))
        XCTAssertTrue(CustomSkillStore.readJsBody(slug: testSlug).contains("v1"))
        try CustomSkillStore.updateJsBody(slug: testSlug, jsBody: """
        window["ai_edge_gallery_get_result"] = async () => "v2";
        """)
        XCTAssertTrue(CustomSkillStore.readJsBody(slug: testSlug).contains("v2"))
        XCTAssertFalse(CustomSkillStore.readJsBody(slug: testSlug).contains("v1"))
    }

    func testDeleteRemovesDirectory() throws {
        try CustomSkillStore.create(CustomSkillDraft(
            slug: testSlug, description: "x", instructions: "y"))
        XCTAssertTrue(CustomSkillStore.exists(slug: testSlug))
        try CustomSkillStore.delete(slug: testSlug)
        XCTAssertFalse(CustomSkillStore.exists(slug: testSlug))
        // Idempotent: second delete shouldn't throw.
        XCTAssertNoThrow(try CustomSkillStore.delete(slug: testSlug))
    }

    func testCustomOverridesBuiltInOnSlugCollision() throws {
        // `query-wikipedia` ships in the bundle; create a custom override
        // and verify scanAll returns the custom version.
        let collidingSlug = "query-wikipedia"
        // If a previous run left a custom override behind, clean up first.
        try? CustomSkillStore.delete(slug: collidingSlug)
        try CustomSkillStore.create(CustomSkillDraft(
            slug: collidingSlug,
            description: "user override of built-in wiki",
            instructions: "custom"))
        defer { try? CustomSkillStore.delete(slug: collidingSlug) }

        let merged = SkillBundle.scanAll()
        let row = try XCTUnwrap(merged.first { $0.slug == collidingSlug })
        XCTAssertEqual(row.source, .custom,
                       "Custom must win on slug collision with a built-in")
        XCTAssertEqual(row.description, "user override of built-in wiki")
    }

    func testExtractJsBodyHandlesUnwrappedSource() {
        let html = """
        <!doctype html><html><body><script>
          window["ai_edge_gallery_get_result"] = async () => "v";
        </script></body></html>
        """
        // No BEGIN/END markers: parser should fall back to the <script>
        // tag's contents so old/imported skills still round-trip.
        let body = CustomSkillStore.extractJsBody(from: html)
        XCTAssertTrue(body.contains("ai_edge_gallery_get_result"))
    }
}

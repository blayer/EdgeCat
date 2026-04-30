import XCTest
@testable import EdgeCat

@MainActor
final class SkillFolderImporterTests: XCTestCase {
    private var tempRoot: URL!
    private var importedSlug: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        if let slug = importedSlug {
            try? CustomSkillStore.delete(slug: slug)
        }
        importedSlug = nil
        super.tearDown()
    }

    func testImportsValidFolder() throws {
        let slug = "test-imp-\(UUID().uuidString.prefix(6).lowercased())"
        importedSlug = slug
        let src = try makeFakeSkill(at: tempRoot, slug: slug,
                                     manifest: """
                                     ---
                                     name: \(slug)
                                     description: imported via fileImporter
                                     ---

                                     ## Instructions

                                     Body.
                                     """,
                                     jsBody: "window['ai_edge_gallery_get_result']=async(d)=>'ok';")
        let manifest = try SkillFolderImporter.importFolder(at: src)
        XCTAssertEqual(manifest.slug, slug)
        XCTAssertEqual(manifest.source, .custom)
        XCTAssertTrue(manifest.hasJsScripts)
        XCTAssertTrue(manifest.description.contains("imported via fileImporter"))

        // Imported manifest should now be discoverable by SkillBundle.
        let scanned = SkillBundle.scanCustom().first { $0.slug == slug }
        XCTAssertNotNil(scanned)
    }

    func testRejectsNonDirectory() throws {
        let file = tempRoot.appendingPathComponent("not-a-dir.txt")
        try Data("hi".utf8).write(to: file)
        XCTAssertThrowsError(try SkillFolderImporter.importFolder(at: file)) { err in
            guard let e = err as? SkillFolderImportError else {
                return XCTFail("expected SkillFolderImportError")
            }
            if case .notADirectory = e {} else {
                XCTFail("expected .notADirectory, got \(e)")
            }
        }
    }

    func testRejectsFolderWithoutManifest() throws {
        let dir = tempRoot.appendingPathComponent("no-manifest", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        XCTAssertThrowsError(try SkillFolderImporter.importFolder(at: dir)) { err in
            guard let e = err as? SkillFolderImportError else {
                return XCTFail("expected SkillFolderImportError")
            }
            if case .missingManifest = e {} else {
                XCTFail("expected .missingManifest, got \(e)")
            }
        }
    }

    func testRefusesDuplicateSlug() throws {
        let slug = "dup-\(UUID().uuidString.prefix(6).lowercased())"
        importedSlug = slug
        let src = try makeFakeSkill(at: tempRoot, slug: slug,
                                     manifest: """
                                     ---
                                     name: \(slug)
                                     description: dup test
                                     ---
                                     """,
                                     jsBody: nil)
        _ = try SkillFolderImporter.importFolder(at: src)
        // Re-creating the source dir with the same name and re-importing
        // should fail with .alreadyExists since it collides with the first.
        XCTAssertThrowsError(try SkillFolderImporter.importFolder(at: src)) { err in
            guard let e = err as? SkillFolderImportError else {
                return XCTFail("expected SkillFolderImportError")
            }
            if case .alreadyExists(let s) = e {
                XCTAssertEqual(s, slug)
            } else {
                XCTFail("expected .alreadyExists, got \(e)")
            }
        }
    }

    func testCopiesScriptsSubdirectoryWhenPresent() throws {
        let slug = "with-scripts-\(UUID().uuidString.prefix(6).lowercased())"
        importedSlug = slug
        let src = try makeFakeSkill(at: tempRoot, slug: slug,
                                     manifest: """
                                     ---
                                     name: \(slug)
                                     description: ships scripts
                                     ---
                                     """,
                                     jsBody: "console.log('hi');")
        let manifest = try SkillFolderImporter.importFolder(at: src)
        XCTAssertTrue(manifest.hasJsScripts,
                      "Should detect scripts/index.html in the destination")
        let dest = try XCTUnwrap(CustomSkillStore.skillsRootURL)
            .appendingPathComponent(slug)
            .appendingPathComponent("scripts/index.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let body = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(body.contains("console.log"))
    }

    // MARK: - Helpers

    private func makeFakeSkill(at root: URL,
                               slug: String,
                               manifest: String,
                               jsBody: String?) throws -> URL {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("SKILL.md"),
                           atomically: true, encoding: .utf8)
        if let jsBody {
            let scripts = dir.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: scripts,
                                                    withIntermediateDirectories: true)
            try jsBody.write(to: scripts.appendingPathComponent("index.html"),
                             atomically: true, encoding: .utf8)
        }
        return dir
    }
}

import Foundation

// Bridges Android's "Import from local" flow to iOS. Android lets the user
// pick a `.zip` of a skill bundle. iOS lacks built-in zip extraction
// without dragging in a dependency, so we accept a *folder* selection
// instead — SwiftUI's `.fileImporter(allowedContentTypes:[.folder])`
// returns a security-scoped URL pointing at the user-picked directory and
// we copy SKILL.md + scripts/ from there into Documents/skills/<slug>/.
//
// Equivalent flow:
//   Android: pick .zip → unzip into  files/skills/<slug>/
//   iOS:    pick .folder → copy contents into Documents/skills/<slug>/

public enum SkillFolderImportError: Error {
    case notADirectory
    case missingManifest
    case directoryUnavailable
    case alreadyExists(String)
    case copyFailed(String)
}

public enum SkillFolderImporter {
    /// Validate + copy a user-picked folder into Documents/skills/<slug>/.
    /// Slug is the source folder's name; rejects names that already exist
    /// (the user has to delete the prior copy first — same as Android's
    /// AddOrEdit "skill already exists" validation).
    @discardableResult
    public static func importFolder(at source: URL) throws -> SkillManifest {
        let started = source.startAccessingSecurityScopedResource()
        defer { if started { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw SkillFolderImportError.notADirectory
        }
        let manifestURL = source.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw SkillFolderImportError.missingManifest
        }
        guard let root = CustomSkillStore.skillsRootURL else {
            throw SkillFolderImportError.directoryUnavailable
        }

        let slug = source.lastPathComponent
        let dst = root.appendingPathComponent(slug, isDirectory: true)
        if fm.fileExists(atPath: dst.path) {
            throw SkillFolderImportError.alreadyExists(slug)
        }
        do {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try copyEntry(from: manifestURL,
                          to: dst.appendingPathComponent("SKILL.md"))
            // Optional `scripts/index.html` — preserve the same layout
            // SkillBundle.scanResources expects so the imported skill
            // becomes a JsSkill on next defaultSet().
            let scriptsSrc = source.appendingPathComponent("scripts", isDirectory: true)
            if fm.fileExists(atPath: scriptsSrc.path) {
                let scriptsDst = dst.appendingPathComponent("scripts", isDirectory: true)
                try fm.createDirectory(at: scriptsDst, withIntermediateDirectories: true)
                let entries = (try? fm.contentsOfDirectory(at: scriptsSrc,
                                                           includingPropertiesForKeys: nil)) ?? []
                for entry in entries {
                    try copyEntry(from: entry,
                                  to: scriptsDst.appendingPathComponent(entry.lastPathComponent))
                }
            }
        } catch let e as SkillFolderImportError {
            try? fm.removeItem(at: dst)
            throw e
        } catch {
            try? fm.removeItem(at: dst)
            throw SkillFolderImportError.copyFailed(error.localizedDescription)
        }

        // Re-scan the manifest we just wrote so the caller (the manager
        // UI) has the parsed metadata to decorate its row.
        guard let raw = try? String(contentsOf: dst.appendingPathComponent("SKILL.md"),
                                    encoding: .utf8),
              let manifest = SkillManifestParser.parse(contents: raw,
                                                        slug: slug,
                                                        hasJsScripts: fm.fileExists(atPath: dst.appendingPathComponent("scripts/index.html").path),
                                                        source: .custom) else {
            try? fm.removeItem(at: dst)
            throw SkillFolderImportError.missingManifest
        }
        return manifest
    }

    /// Atomically copy a single entry. Avoids `FileManager.copyItem`
    /// because the source URL might live on a Files Provider that doesn't
    /// support `copy:` directly — read-then-write is universally safe.
    private static func copyEntry(from src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src)
        try data.write(to: dst, options: .atomic)
    }
}

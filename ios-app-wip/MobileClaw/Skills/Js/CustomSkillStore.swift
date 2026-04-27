import Foundation

// User-authored JS skills live under Documents/skills/<slug>/, mirroring
// the bundle layout (SKILL.md + scripts/index.html). They override
// built-in skills with the same slug and are the only ones the manager UI
// allows editing or deleting.
//
// Mirrors android-app/.../customtasks/agentchat/SkillManagerViewModel.kt's
// `saveSkillEdit` + custom-skill lifecycle, narrowed to what the iOS UI
// surfaces today (no remote import, no script rename).

public enum CustomSkillStoreError: Error {
    case directoryUnavailable
    case slugInvalid
    case alreadyExists(String)
    case notFound(String)
}

/// Bag-of-fields for create/updateMetadata so we don't drag a 6-arg
/// function signature past SwiftLint's `function_parameter_count` rule.
public struct CustomSkillDraft: Sendable, Equatable {
    public var slug: String
    public var description: String
    public var instructions: String
    public var requireSecret: Bool
    public var requireSecretDescription: String
    public var jsBody: String

    public init(slug: String, description: String, instructions: String,
                requireSecret: Bool = false, requireSecretDescription: String = "",
                jsBody: String = "") {
        self.slug = slug; self.description = description; self.instructions = instructions
        self.requireSecret = requireSecret
        self.requireSecretDescription = requireSecretDescription
        self.jsBody = jsBody
    }
}

public enum CustomSkillStore {
    /// Documents/skills/ — created lazily on first call. `nil` only when
    /// FileManager can't resolve the documents directory at all (host
    /// platform issue, never seen on real iOS).
    static var skillsRootURL: URL? {
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true) else { return nil }
        let dir = docs.appendingPathComponent("skills", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True iff a custom skill with this slug already exists.
    public static func exists(slug: String) -> Bool {
        guard let root = skillsRootURL else { return false }
        return FileManager.default.fileExists(atPath:
            root.appendingPathComponent(slug).path)
    }

    /// Create a new custom skill. Empty `jsBody` is allowed — the row will
    /// show up in the manager but won't appear in the planner catalog
    /// until `scripts/index.html` is non-empty (`hasJsScripts == false`).
    public static func create(_ draft: CustomSkillDraft) throws {
        guard isValidSlug(draft.slug) else { throw CustomSkillStoreError.slugInvalid }
        guard let root = skillsRootURL else { throw CustomSkillStoreError.directoryUnavailable }
        let dir = root.appendingPathComponent(draft.slug, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            throw CustomSkillStoreError.alreadyExists(draft.slug)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeManifest(in: dir, draft: draft)
        try writeJsBody(in: dir, jsBody: draft.jsBody)
    }

    /// Replace `description` / `instructions` / secret metadata on an
    /// existing custom skill. The slug is immutable to avoid invalidating
    /// the planner's tool-catalog references mid-conversation. JS body is
    /// untouched here — call `updateJsBody` for that.
    public static func updateMetadata(_ draft: CustomSkillDraft) throws {
        guard let root = skillsRootURL else { throw CustomSkillStoreError.directoryUnavailable }
        let dir = root.appendingPathComponent(draft.slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw CustomSkillStoreError.notFound(draft.slug)
        }
        try writeManifest(in: dir, draft: draft)
    }

    /// Replace the JS body for an existing custom skill.
    public static func updateJsBody(slug: String, jsBody: String) throws {
        guard let root = skillsRootURL else { throw CustomSkillStoreError.directoryUnavailable }
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw CustomSkillStoreError.notFound(slug)
        }
        try writeJsBody(in: dir, jsBody: jsBody)
    }

    /// Read the current JS body if any. Returns "" when the file is
    /// missing — used by the editor to seed the textarea on first open.
    public static func readJsBody(slug: String) -> String {
        guard let root = skillsRootURL else { return "" }
        let html = root.appendingPathComponent(slug)
                        .appendingPathComponent("scripts/index.html")
        guard let raw = try? String(contentsOf: html, encoding: .utf8) else { return "" }
        return extractJsBody(from: raw)
    }

    /// Remove the entire `<slug>/` directory. Idempotent.
    public static func delete(slug: String) throws {
        guard let root = skillsRootURL else { throw CustomSkillStoreError.directoryUnavailable }
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Internals

    /// Slug must be filesystem-safe and stable enough for the planner's
    /// tool catalog: lowercase ASCII, digits, dashes; 2-50 chars. Tighter
    /// than Android's regex but safe for our cases.
    static func isValidSlug(_ slug: String) -> Bool {
        guard (2...50).contains(slug.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return slug.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func writeManifest(in dir: URL, draft: CustomSkillDraft) throws {
        let yaml = """
        ---
        name: \(draft.slug)
        description: \(yamlEscape(draft.description))
        require-secret: \(draft.requireSecret ? "true" : "false")
        require-secret-description: \(yamlEscape(draft.requireSecretDescription))
        ---

        # \(draft.slug)

        ## Instructions

        \(draft.instructions)
        """
        try yaml.write(to: dir.appendingPathComponent("SKILL.md"),
                       atomically: true, encoding: .utf8)
    }

    private static func writeJsBody(in dir: URL, jsBody: String) throws {
        let scripts = dir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts,
                                                withIntermediateDirectories: true)
        // Wrap the user's JS body in a minimal HTML host that defines the
        // canonical entry point. The user's JS is dropped in verbatim —
        // they're expected to define `window["ai_edge_gallery_get_result"]`
        // themselves; the placeholder default is just so an empty body
        // doesn't crash on `evaluateJavaScript`.
        let html = """
        <!doctype html><html><body><script>
        // BEGIN_USER_JS
        \(jsBody)
        // END_USER_JS
        if (typeof window["ai_edge_gallery_get_result"] !== 'function') {
          window["ai_edge_gallery_get_result"] = async () =>
            JSON.stringify({ error: "skill not implemented yet — define window['ai_edge_gallery_get_result']" });
        }
        </script></body></html>
        """
        try html.write(to: scripts.appendingPathComponent("index.html"),
                       atomically: true, encoding: .utf8)
    }

    /// Pull the user-authored JS back out of the wrapper html for
    /// re-display in the editor. Tolerates a missing wrapper by returning
    /// the whole `<script>` body.
    static func extractJsBody(from html: String) -> String {
        if let begin = html.range(of: "// BEGIN_USER_JS"),
           let end = html.range(of: "// END_USER_JS"), begin.upperBound < end.lowerBound {
            return String(html[begin.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fall back to the entire <script> tag's contents.
        if let openTag = html.range(of: "<script"),
           let openEnd = html.range(of: ">", range: openTag.upperBound..<html.endIndex),
           let closeTag = html.range(of: "</script>") {
            return String(html[openEnd.upperBound..<closeTag.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return html
    }

    /// Quote and escape a value for inline YAML. We always emit values in
    /// double-quoted form so multi-word descriptions and special chars
    /// don't trip the parser.
    private static func yamlEscape(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}

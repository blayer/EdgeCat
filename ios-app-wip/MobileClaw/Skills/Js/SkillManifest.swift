import Foundation

// 1:1 port of android-app/.../customtasks/agentchat/SkillManagerViewModel.kt's
// `convertSkillMdToProto` parser, scoped to the iOS bundle. Each
// `Resources/skills/<slug>/SKILL.md` file follows the same shape as the
// Android assets:
//
//     ---
//     name: query-wikipedia
//     description: Query summary from Wikipedia for a given topic.
//     require-secret: false
//     require-secret-description: ""
//     homepage: https://wikipedia.org
//     ---
//
//     # Title
//
//     ## Instructions
//
//     <body — usage instructions for the planner>
//
// Empty/missing keys default to safe values. Keys outside the YAML block are
// ignored. Body parsing stops at end-of-file.

public struct SkillManifest: Sendable, Equatable {
    /// Where the manifest lives. Built-in manifests are read-only; custom
    /// ones live under Documents/skills/ and can be edited or deleted.
    public enum Source: String, Sendable, Equatable {
        case builtIn
        case custom
    }

    public let slug: String
    public let name: String
    public let description: String
    public let requireSecret: Bool
    public let requireSecretDescription: String
    public let homepage: String
    public let instructions: String
    /// Set when `<root>/skills/<slug>/scripts/index.html` exists alongside
    /// the manifest. Skills without scripts are still listed (for native
    /// counterparts) but shouldn't be wrapped in a `JsSkill`.
    public let hasJsScripts: Bool
    public let source: Source

    public init(slug: String, name: String, description: String,
                requireSecret: Bool = false, requireSecretDescription: String = "",
                homepage: String = "", instructions: String = "",
                hasJsScripts: Bool = false,
                source: Source = .builtIn) {
        self.slug = slug; self.name = name; self.description = description
        self.requireSecret = requireSecret
        self.requireSecretDescription = requireSecretDescription
        self.homepage = homepage; self.instructions = instructions
        self.hasJsScripts = hasJsScripts
        self.source = source
    }
}

public enum SkillManifestParser {
    /// Parse a SKILL.md file's contents. `slug` is the directory name on
    /// disk; we don't trust the file's `name:` field for routing because two
    /// folders could declare the same display name. `hasJsScripts` reflects
    /// what the caller already verified on the filesystem.
    public static func parse(contents: String, slug: String, hasJsScripts: Bool,
                             source: SkillManifest.Source = .builtIn) -> SkillManifest? {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return nil }

        // Locate the closing `---` of the YAML frontmatter.
        let afterOpen = trimmed.dropFirst(3)
        guard let closeRange = afterOpen.range(of: "\n---") else { return nil }

        let yaml = String(afterOpen[..<closeRange.lowerBound])
        let body = String(afterOpen[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [String: String] = [:]
        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes (both " and ') if present.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }

        // `name:` isn't required by Android's parser but the planner needs a
        // display name. Fall back to the slug if the field is missing or
        // empty.
        let displayName: String = {
            if let n = fields["name"], !n.isEmpty { return n }
            return slug
        }()
        let description = fields["description"] ?? ""
        let requireSecret = (fields["require-secret"] ?? "false").lowercased() == "true"
        let requireSecretDescription = fields["require-secret-description"] ?? ""
        let homepage = fields["homepage"] ?? ""
        // Instructions are the prose under `## Instructions` if present;
        // otherwise the entire body. Matches Android's loose handling.
        let instructions: String = {
            if let range = body.range(of: "## Instructions") {
                return body[range.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return body
        }()

        return SkillManifest(slug: slug, name: displayName, description: description,
                             requireSecret: requireSecret,
                             requireSecretDescription: requireSecretDescription,
                             homepage: homepage, instructions: instructions,
                             hasJsScripts: hasJsScripts,
                             source: source)
    }
}

public enum SkillBundle {
    /// Walk one `<root>/skills/<slug>/` tree, parse every SKILL.md, and
    /// return one manifest per directory. Source (built-in vs custom) is
    /// stamped onto each manifest so callers can decide what's editable.
    static func scan(root: URL, source: SkillManifest.Source) -> [SkillManifest] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let dirs = (try? fm.contentsOfDirectory(at: root,
                                                includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        var manifests: [SkillManifest] = []
        for dir in dirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let slug = dir.lastPathComponent
            let mdURL = dir.appendingPathComponent("SKILL.md")
            guard let contents = try? String(contentsOf: mdURL, encoding: .utf8) else {
                continue
            }
            let scriptsHTML = dir.appendingPathComponent("scripts/index.html")
            let hasJs = fm.fileExists(atPath: scriptsHTML.path)
            if let manifest = SkillManifestParser.parse(contents: contents,
                                                        slug: slug,
                                                        hasJsScripts: hasJs,
                                                        source: source) {
                manifests.append(manifest)
            }
        }
        return manifests
    }

    /// Walk built-in skills shipped in the app bundle.
    public static func scanResources(bundle: Bundle = .main) -> [SkillManifest] {
        // The `skills/` directory ships via a postBuildScript rsync in
        // project.yml — xcodegen 2.45 silently drops `type: folder`
        // resources, so `url(forResource:)` can't find it. Reach into
        // `resourceURL` directly.
        guard let resources = bundle.resourceURL else { return [] }
        let root = resources.appendingPathComponent("skills", isDirectory: true)
        return scan(root: root, source: .builtIn).sorted { $0.slug < $1.slug }
    }

    /// Walk user-authored skills under Documents/skills/. These are
    /// editable, deletable, and override built-ins of the same slug.
    public static func scanCustom() -> [SkillManifest] {
        guard let root = CustomSkillStore.skillsRootURL else { return [] }
        return scan(root: root, source: .custom).sorted { $0.slug < $1.slug }
    }

    /// Merged catalog: built-ins + custom, with custom winning on slug
    /// collisions. The planner + manager UI both consume this.
    public static func scanAll(bundle: Bundle = .main) -> [SkillManifest] {
        let built = scanResources(bundle: bundle)
        let custom = scanCustom()
        var bySlug: [String: SkillManifest] = [:]
        for m in built  { bySlug[m.slug] = m }
        for m in custom { bySlug[m.slug] = m }   // custom wins
        return bySlug.values.sorted { $0.slug < $1.slug }
    }
}

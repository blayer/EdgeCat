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
    public let slug: String
    public let name: String
    public let description: String
    public let requireSecret: Bool
    public let requireSecretDescription: String
    public let homepage: String
    public let instructions: String
    /// Set when `Resources/skills/<slug>/scripts/index.html` exists alongside
    /// the manifest. Skills without scripts are still listed (for native
    /// counterparts) but shouldn't be wrapped in a `JsSkill`.
    public let hasJsScripts: Bool

    public init(slug: String, name: String, description: String,
                requireSecret: Bool = false, requireSecretDescription: String = "",
                homepage: String = "", instructions: String = "",
                hasJsScripts: Bool = false) {
        self.slug = slug; self.name = name; self.description = description
        self.requireSecret = requireSecret
        self.requireSecretDescription = requireSecretDescription
        self.homepage = homepage; self.instructions = instructions
        self.hasJsScripts = hasJsScripts
    }
}

public enum SkillManifestParser {
    /// Parse a SKILL.md file's contents. `slug` is the directory name on
    /// disk; we don't trust the file's `name:` field for routing because two
    /// folders could declare the same display name. `hasJsScripts` reflects
    /// what the caller already verified on the filesystem.
    public static func parse(contents: String, slug: String, hasJsScripts: Bool) -> SkillManifest? {
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
                             hasJsScripts: hasJsScripts)
    }
}

public enum SkillBundle {
    /// Walk `Resources/skills/<slug>/` inside the app bundle, parse every
    /// SKILL.md, and return one manifest per directory. Skips directories
    /// that fail to parse — those never reach the planner.
    public static func scanResources(bundle: Bundle = .main) -> [SkillManifest] {
        // The `skills/` directory is included as a folder reference in
        // project.yml (`type: folder`), which means `url(forResource:)`
        // can't find it — folder references aren't part of the resource
        // catalog. Reach into `resourceURL` instead and look for the
        // directory directly.
        guard let resources = bundle.resourceURL else { return [] }
        let skillsRoot = resources.appendingPathComponent("skills", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: skillsRoot.path) else { return [] }
        let dirs = (try? fm.contentsOfDirectory(at: skillsRoot,
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
                                                        hasJsScripts: hasJs) {
                manifests.append(manifest)
            }
        }
        return manifests.sorted { $0.slug < $1.slug }
    }
}

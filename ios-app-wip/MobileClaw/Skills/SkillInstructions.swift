import Foundation

// User overrides for per-skill instructions. The default value comes from
// the bundled SKILL.md (or a custom skill's SKILL.md, which is editable
// directly via CustomSkillStore). For built-in skills the SKILL.md is
// read-only at runtime, so user-authored instruction tweaks have to land
// somewhere else — UserDefaults, keyed by skill slug.
//
// Mirrors android-app's `saveSkillEdit` for built-in skills, where
// instruction-only overrides are persisted in DataStore separately from
// the bundled asset.

public enum SkillInstructions {
    static let storeKey = "MOBILECLAW_SKILL_INSTRUCTIONS"

    /// Returns the user override if one exists, else nil. Callers can
    /// fall back to the manifest's default `instructions` field.
    public static func override(for slug: String) -> String? {
        let dict = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]
        let value = dict?[slug] ?? ""
        return value.isEmpty ? nil : value
    }

    /// Effective instructions for a slug — override if set, else default.
    public static func effective(slug: String, default defaultValue: String) -> String {
        override(for: slug) ?? defaultValue
    }

    /// Save or clear the override. Empty string deletes the entry so the
    /// SKILL.md default re-takes effect.
    public static func setOverride(_ value: String?, for slug: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]
        if let value, !value.isEmpty {
            dict[slug] = value
        } else {
            dict.removeValue(forKey: slug)
        }
        UserDefaults.standard.set(dict, forKey: storeKey)
    }

    /// Clear every override. Used by a full app reset and when a custom
    /// skill is deleted (so a future built-in with the same slug doesn't
    /// inherit the deleted skill's stale overrides).
    public static func clear(slug: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]
        dict.removeValue(forKey: slug)
        UserDefaults.standard.set(dict, forKey: storeKey)
    }
}

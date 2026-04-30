import Foundation

// Per-skill enabled/disabled toggle state. Mirrors Android's `SkillState`
// proto field `selected`. Stored as a single UserDefaults `[String: Bool]`
// dict keyed by skill name. The default for an unknown skill is `true`
// (newly bundled skills opt-in by default — matching Android's behavior
// where unseen skills appear pre-checked the first time).

public enum SkillToggles {
    static let storeKey = "EDGECAT_SKILL_TOGGLES"

    /// "Base" skills are always-enabled and don't appear in the manager UI.
    /// Mirrors Android's `BASE_SKILLS` set — currently empty on iOS so the
    /// user has full control. If we ever introduce a privacy-critical
    /// skill that should never be turned off, name it here.
    public static let baseSkills: Set<String> = []

    public static func isEnabled(_ name: String) -> Bool {
        if baseSkills.contains(name) { return true }
        let dict = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Bool]
        return dict?[name] ?? true
    }

    public static func setEnabled(_ enabled: Bool, for name: String) {
        if baseSkills.contains(name) { return }
        var dict = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Bool]) ?? [:]
        dict[name] = enabled
        UserDefaults.standard.set(dict, forKey: storeKey)
    }

    /// Bulk operation — used by the Manager UI's "Turn On All / Off All"
    /// button. Honors the base-skill list (those rows can't be flipped off
    /// even via bulk toggle).
    public static func setAllEnabled(_ enabled: Bool, in names: [String]) {
        var dict = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: Bool]) ?? [:]
        for n in names where !baseSkills.contains(n) {
            dict[n] = enabled
        }
        UserDefaults.standard.set(dict, forKey: storeKey)
    }

    /// Reset everything to default (= enabled). Lets the Manager UI surface
    /// a "Reset" affordance later without leaking implementation details.
    public static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}

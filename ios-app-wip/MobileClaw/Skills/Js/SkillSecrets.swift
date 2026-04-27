import Foundation
import Security

// 1:1 functional port of android-app/.../customtasks/agentchat
// /SkillManagerViewModel.kt's per-skill secret storage. Keychain entries are
// keyed by `skillName`; the value is whatever the user pasted into the
// secret-editor sheet (typically an API key like a Brave / SerpApi token).
//
// Mirrors `HuggingFaceAuth`'s pattern: one service per concern, one account
// per skill. Stored only on-device; never synced to iCloud.

public enum SkillSecrets {
    private static let service = "com.mobileclawapp.app.skillSecrets"

    /// Returns the saved secret for `skillName`, or nil if none.
    public static func token(for skillName: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: skillName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Stores or replaces the secret for `skillName`. Pass `nil` to delete.
    public static func setToken(_ token: String?, for skillName: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: skillName,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    /// True iff a non-empty secret is stored. Used by SkillManagerView to
    /// decorate rows with a "key set" indicator.
    public static func hasToken(for skillName: String) -> Bool {
        guard let t = token(for: skillName) else { return false }
        return !t.isEmpty
    }
}

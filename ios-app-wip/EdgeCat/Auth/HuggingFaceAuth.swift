import Foundation
import Security

// Mirrors android-app's HuggingFace token storage. iOS uses Keychain for
// at-rest secret storage. Token is a user access token from
// huggingface.co/settings/tokens — paste-in flow for Phase B; a full
// ASWebAuthenticationSession OAuth dance can replace it later.

public enum HuggingFaceAuth {
    private static let service = "com.edgecat.app.huggingface"
    private static let account = "user-token"

    public static func setToken(_ token: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func token() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    public static var hasToken: Bool { token() != nil }
}

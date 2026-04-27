import Foundation
import AuthenticationServices
import UIKit

// 1:1 port of android-app's HF OAuth (net.openid.appauth) but using Apple's
// system ASWebAuthenticationSession. The user taps "Sign in with HuggingFace"
// in SettingsView; we open the HF authorize endpoint, capture the redirect
// at mobileclaw://hf-callback, exchange the code for a token, store it via
// the existing HuggingFaceAuth (Keychain).
//
// HuggingFace requires the app to be registered at
// https://huggingface.co/settings/connected-applications. Set the client ID
// here once you have one — until then the session falls back to the paste-in
// token field that already works.

public enum HuggingFaceOAuthSession {
    /// Set this to your HF OAuth app's client_id once registered.
    /// Empty value disables OAuth and the SettingsView button stays hidden.
    public static let clientId: String = ""
    public static let redirectScheme = "mobileclaw"
    public static let redirectURL = "mobileclaw://hf-callback"
    public static let scope = "read-repos"

    public enum AuthError: Error, LocalizedError {
        case notConfigured, cancelled, missingCode, exchangeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "HF OAuth client_id not configured"
            case .cancelled: return "Sign-in cancelled"
            case .missingCode: return "Authorization code missing"
            case .exchangeFailed(let m): return "Token exchange failed: \(m)"
            }
        }
    }

    @MainActor
    public static func signIn() async throws {
        guard !clientId.isEmpty else { throw AuthError.notConfigured }
        let state = UUID().uuidString
        guard var comps = URLComponents(string: "https://huggingface.co/oauth/authorize") else {
            throw AuthError.exchangeFailed("invalid authorize URL")
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURL),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
        ]
        guard let authURL = comps.url else { throw AuthError.notConfigured }

        let callbackURL: URL = try await withCheckedThrowingContinuation { cont in
            let presenter = AuthPresenter()
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: redirectScheme
            ) { url, error in
                if let url { cont.resume(returning: url) }
                else if let error { cont.resume(throwing: error) }
                else { cont.resume(throwing: AuthError.cancelled) }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            objc_setAssociatedObject(session, &presenterKey, presenter, .OBJC_ASSOCIATION_RETAIN)
            session.start()
        }

        guard let qs = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
              let code = qs.first(where: { $0.name == "code" })?.value else {
            throw AuthError.missingCode
        }
        let returnedState = qs.first(where: { $0.name == "state" })?.value
        guard returnedState == state else {
            throw AuthError.exchangeFailed("state mismatch")
        }

        // Exchange the code for an access token.
        guard let tokenURL = URL(string: "https://huggingface.co/oauth/token") else {
            throw AuthError.exchangeFailed("invalid token URL")
        }
        var tokenReq = URLRequest(url: tokenURL)
        tokenReq.httpMethod = "POST"
        tokenReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=authorization_code",
            "client_id=\(clientId)",
            "code=\(code)",
            "redirect_uri=\(redirectURL)",
        ].joined(separator: "&")
        tokenReq.httpBody = body.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: tokenReq)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw AuthError.exchangeFailed(String(data: data, encoding: .utf8) ?? "unknown")
        }
        HuggingFaceAuth.setToken(token)
    }
}

private var presenterKey: UInt8 = 0

private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow ?? ASPresentationAnchor()
    }
}

import XCTest
@testable import MobileClaw

/// Friendly error formatting for download failures. Specifically guards
/// against leaking raw `NSURLErrorDomain Code=-999 …` strings (cancellation)
/// or raw `HTTP nnn — model may be HF-gated` (server response codes) into
/// the user-facing error bubble.
final class ModelDownloaderErrorMessageTests: XCTestCase {

    // MARK: - HTTP code mapping

    func testHttpUnauthorizedSuggestsSignIn() {
        let msg = ModelDownloader.friendlyHttpMessage(code: 401)
        XCTAssertTrue(msg.contains("Sign in"),
                      "401 should prompt the user to sign in to HF, got: \(msg)")
    }

    func testHttpForbiddenSuggestsGatedAcceptance() {
        let msg = ModelDownloader.friendlyHttpMessage(code: 403)
        XCTAssertTrue(msg.lowercased().contains("gated") ||
                       msg.lowercased().contains("accept"),
                       "403 should mention gating / terms, got: \(msg)")
    }

    func testHttpNotFoundReportsCatalogIssue() {
        let msg = ModelDownloader.friendlyHttpMessage(code: 404)
        XCTAssertTrue(msg.lowercased().contains("not found"))
    }

    func testHttp500SeriesBlamesServer() {
        for code in [500, 502, 503, 599] {
            let msg = ModelDownloader.friendlyHttpMessage(code: code)
            XCTAssertTrue(msg.contains("Hugging Face"),
                          "5xx should mention Hugging Face server, got: \(msg) for \(code)")
        }
    }

    func testHttpRateLimitMentionsRateLimit() {
        let msg = ModelDownloader.friendlyHttpMessage(code: 429)
        XCTAssertTrue(msg.lowercased().contains("rate"))
    }

    func testUnknownHttpFallsBackToGenericMessage() {
        let msg = ModelDownloader.friendlyHttpMessage(code: 418)
        XCTAssertEqual(msg, "Download failed (HTTP 418).",
                       "Unknown codes should still be friendly + include the code for support")
    }

    // MARK: - Transport error mapping

    func testNoInternetMapsToFriendlyMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let msg = ModelDownloader.friendlyTransportMessage(err)
        XCTAssertTrue(msg.lowercased().contains("internet"))
        XCTAssertFalse(msg.contains("NSURLErrorDomain"),
                       "Friendly message must not leak the NSError domain")
    }

    func testTimedOutMapsToFriendlyMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let msg = ModelDownloader.friendlyTransportMessage(err)
        XCTAssertTrue(msg.lowercased().contains("timed out"))
    }

    func testDnsFailureMapsToConnectivityMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let msg = ModelDownloader.friendlyTransportMessage(err)
        XCTAssertTrue(msg.lowercased().contains("hugging face") ||
                       msg.lowercased().contains("connection"))
    }

    func testCertificateFailureMapsToFriendlyMessage() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        let msg = ModelDownloader.friendlyTransportMessage(err)
        XCTAssertTrue(msg.lowercased().contains("secure"))
    }

    func testUnknownTransportFallsBackToGeneric() {
        let err = NSError(domain: "SomeOtherDomain", code: 42)
        let msg = ModelDownloader.friendlyTransportMessage(err)
        XCTAssertEqual(msg, "Download failed. Please try again.")
    }

    func testTransportMessageNeverContainsRawDescription() {
        // The raw NSError userInfo description has been a source of leaked
        // text in the past — guard against it explicitly.
        let err = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."])
        let msg = ModelDownloader.friendlyTransportMessage(err)
        XCTAssertFalse(msg.contains("NSURLErrorDomain"))
        XCTAssertFalse(msg.contains("Code="),
                       "User-facing string must not leak the raw NSError description")
    }
}

import XCTest
@testable import EdgeCat

/// Verifies the `enable_thinking` plumbing from the orchestration layer
/// down through the `extra_context` JSON arg the LiteRtLm C library
/// reads. Mirrors the Android Gallery's `extraContext = mapOf("enable_thinking"
/// to "true"|"false")` convention so the C-side `enable_thinking` parser
/// sees the same encoding on both platforms.
final class LiteRtLmThinkingToggleTests: XCTestCase {

    // MARK: - Provider-level mapping

    func testEnableThinkingTrueMapsToTrueString() {
        let ctx = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: true)
        XCTAssertEqual(ctx, ["enable_thinking": "true"],
                       "enableThinking=true must produce {\"enable_thinking\":\"true\"}")
    }

    func testEnableThinkingFalseMapsToFalseString() {
        let ctx = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: false)
        XCTAssertEqual(ctx, ["enable_thinking": "false"],
                       "enableThinking=false must produce {\"enable_thinking\":\"false\"}")
    }

    func testExtraContextHasExactlyOneKey() {
        // Catches accidental key bloat (extra entries forwarded to the
        // C-side that we don't actually understand). Add new keys only
        // alongside a corresponding test asserting the new value shape.
        for flag in [true, false] {
            let ctx = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: flag)
            XCTAssertEqual(Set(ctx.keys), ["enable_thinking"],
                           "extra_context must contain exactly the enable_thinking key")
        }
    }

    // MARK: - JSON-shape contract (matches Android Gallery)

    /// The bridge serializes the dict via `NSJSONSerialization`. The
    /// resulting JSON must carry the value as a STRING (`"true"`),
    /// matching the Android Gallery's `mapOf("enable_thinking" to "true")`
    /// shape. A naive Swift port that used Bool would emit
    /// `{"enable_thinking":true}` and the C-side parser (which expects
    /// the string form) would treat it as missing.
    func testBridgeShouldSerializeValuesAsJsonStringsNotBools() throws {
        let ctx = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: true)
        let data = try JSONSerialization.data(withJSONObject: ctx, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(json, #"{"enable_thinking":"true"}"#,
                       "JSON value must be the STRING \"true\", not the bare bool true")
    }

    func testBridgeJsonIsAlwaysValidEvenWhenEmpty() throws {
        // When the orchestration layer doesn't care (legacy / chat path),
        // an empty dict must serialize to "{}" so the C library's
        // extra_context parse doesn't choke on a null pointer.
        let empty: [String: String] = [:]
        let data = try JSONSerialization.data(withJSONObject: empty, options: [])
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(json, "{}")
    }
}

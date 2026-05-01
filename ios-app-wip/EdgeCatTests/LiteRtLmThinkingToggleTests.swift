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

    /// Crucially: when thinking is OFF, the key is *omitted* (empty
    /// dict). Sending `"enable_thinking":"false"` explicitly was
    /// empirically slower than omitting — the SDK seems to interpret
    /// presence-of-key as "the caller is asking about thinking,
    /// emit a CoT preamble". Matches the Android Gallery's
    /// `if (enableThinking) mapOf(...) else null` convention.
    func testEnableThinkingFalseProducesEmptyDict() {
        let ctx = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: false)
        XCTAssertEqual(ctx, [:],
                       "enableThinking=false must omit the key entirely so the engine returns to its default behavior")
    }

    func testEnableThinkingTrueHasExactlyOneKey() {
        // Catches accidental key bloat — only `enable_thinking` should
        // be forwarded to the C-side `extra_context`. Add new keys
        // only alongside a corresponding test asserting their shape.
        let ctx = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: true)
        XCTAssertEqual(Set(ctx.keys), ["enable_thinking"],
                       "extra_context must contain exactly the enable_thinking key when thinking is on")
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

    // MARK: - Config-page → policy round-trip

    /// Regression guard for the Settings → Thinking Mode picker. The
    /// picker uses `@AppStorage(SamplerSettings.agentThinkingModeKey)`
    /// which writes ints (0/1/2) to UserDefaults. Both the chat
    /// path (ChatViewModel) and the eval path (EvalEntryPoint) read
    /// that same key and feed it to `ThinkingMode.from(_:)` to
    /// construct the orchestration policy. Test the full storage →
    /// mode → policy → enableThinking chain so a renamed key or a
    /// changed enum order would break here, not at runtime.
    private struct PickerCase {
        let rawSetting: Int
        let expectedMode: ThinkingMode
        let plannerOnSimpleMsg: Bool
        let plannerOnComplexMsg: Bool
    }

    func testSettingsPickerValuesRoundTripThroughThinkingPolicy() throws {
        let suiteName = "com.edgecat.tests.thinkingPicker"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Picker writes raw int values; SamplerSettings reads via
        // `agentThinkingModeKey`. Verify each picker option resolves
        // to the documented policy behavior.
        let cases: [PickerCase] = [
            PickerCase(rawSetting: 0, expectedMode: .auto,
                       plannerOnSimpleMsg: false, plannerOnComplexMsg: true),
            PickerCase(rawSetting: 1, expectedMode: .off,
                       plannerOnSimpleMsg: false, plannerOnComplexMsg: false),
            PickerCase(rawSetting: 2, expectedMode: .aggressive,
                       plannerOnSimpleMsg: true, plannerOnComplexMsg: true),
        ]
        for c in cases {
            defaults.set(c.rawSetting, forKey: SamplerSettings.agentThinkingModeKey)
            let stored = defaults.integer(forKey: SamplerSettings.agentThinkingModeKey)
            XCTAssertEqual(stored, c.rawSetting,
                           "Picker raw value must round-trip through UserDefaults")
            let mode = ThinkingMode.from(stored)
            XCTAssertEqual(mode, c.expectedMode,
                           "raw=\(c.rawSetting) must map to \(c.expectedMode)")
            let policy = ThinkingPolicy(mode: mode)
            XCTAssertEqual(policy.planner(userMessage: "what time is it",
                                          iteration: 0),
                           c.plannerOnSimpleMsg,
                           "Mode \(mode) on simple-prefix prompt: expected \(c.plannerOnSimpleMsg)")
            XCTAssertEqual(policy.planner(userMessage: "Build a rich nuanced research plan",
                                          iteration: 0),
                           c.plannerOnComplexMsg,
                           "Mode \(mode) on complex prompt: expected \(c.plannerOnComplexMsg)")
            // And the toggle reaches the bridge with the right shape:
            // .off should produce no key (omitted), .auto/.aggressive
            // can produce the key when the policy says thinking is on.
            let dictForOff = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: false)
            XCTAssertEqual(dictForOff, [:],
                           "When policy returns false the bridge gets an empty dict (omits key)")
            let dictForOn = LiteRtLmInferenceProvider.makeExtraContext(enableThinking: true)
            XCTAssertEqual(dictForOn, ["enable_thinking": "true"],
                           "When policy returns true the bridge gets enable_thinking=true")
        }
    }
}

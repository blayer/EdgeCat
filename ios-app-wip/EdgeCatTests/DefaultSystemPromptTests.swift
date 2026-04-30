import XCTest
@testable import EdgeCat

/// Default system prompt parity with Android (`AgentChatTask.defaultSystemPrompt`).
/// We don't assert byte-equality — iOS drops the `___SKILLS___` placeholder
/// because the planner builds the catalog itself and chat-mode doesn't
/// have tool-calling — but the *intent* (helpful assistant + "output only
/// the final result") must be preserved so Gemma's chat behavior matches.
final class DefaultSystemPromptTests: XCTestCase {

    func testDefaultSystemPromptIsNonEmpty() {
        XCTAssertFalse(SamplerSettings.defaultSystemPrompt.isEmpty)
    }

    func testDefaultMentionsHelpfulAssistant() {
        XCTAssertTrue(
            SamplerSettings.defaultSystemPrompt.contains("helpful AI assistant"),
            "Mirrors Android's 'You are a helpful AI assistant…' opener"
        )
    }

    func testDefaultIncludesOutputOnlyFinalResultGuidance() {
        XCTAssertTrue(
            SamplerSettings.defaultSystemPrompt.contains("ONLY the final result"),
            "Drops Gemma's chain-of-thought from chat replies — the high-impact line on Android"
        )
    }

    func testDefaultDropsAndroidSkillsPlaceholder() {
        // ___SKILLS___ is Android's templated injection point. iOS doesn't
        // use the conversation's system prompt to advertise skills (the
        // planner builds its own catalog), so the literal placeholder
        // shouldn't appear here.
        XCTAssertFalse(
            SamplerSettings.defaultSystemPrompt.contains("___SKILLS___"),
            "iOS planner injects the skill catalog itself; the system prompt should not contain the Android placeholder"
        )
    }

    func testDefaultIsBoundedSoItDoesntEatTheContextWindow() {
        // Heuristic: a prompt with more than 1000 chars eats too much KV
        // cache for a 4096-token Gemma 4 E2B context. Android's prompt
        // is ~250 chars; we should be in the same ballpark.
        XCTAssertLessThan(
            SamplerSettings.defaultSystemPrompt.count, 600,
            "Default prompt is too long; will reduce the user's effective context window"
        )
    }
}

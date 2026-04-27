import XCTest
@testable import MobileClaw

/// Mirrors android-app/.../PlannerTest.kt `classifyIntent` cases. Keep this
/// file 1:1 with the Android cases — when Android adds a new pattern we add
/// the matching case here.
final class IntentClassifierTests: XCTestCase {

    // MARK: - Chat patterns

    func testGreetingsRouteToChat() {
        for msg in ["hi", "hey there", "hello", "howdy", "yo", "sup"] {
            XCTAssertEqual(IntentClassifier.classify(msg), .chat,
                           "Expected '\(msg)' → chat")
        }
    }

    func testGoodMorningRoutesToChat() {
        XCTAssertEqual(IntentClassifier.classify("good morning"), .chat)
        XCTAssertEqual(IntentClassifier.classify("Good evening"), .chat)
    }

    func testThanksRoutesToChat() {
        XCTAssertEqual(IntentClassifier.classify("thanks"), .chat)
        XCTAssertEqual(IntentClassifier.classify("thank you"), .chat)
    }

    func testGoodbyesRouteToChat() {
        for msg in ["bye", "goodbye", "see you", "later"] {
            XCTAssertEqual(IntentClassifier.classify(msg), .chat,
                           "Expected '\(msg)' → chat")
        }
    }

    func testSingleWordAffirmativesRouteToChat() {
        for msg in ["ok", "okay", "sure", "great", "nice", "cool", "awesome"] {
            XCTAssertEqual(IntentClassifier.classify(msg), .chat,
                           "Expected '\(msg)' → chat")
        }
    }

    func testIdentityQuestionsRouteToChat() {
        XCTAssertEqual(IntentClassifier.classify("who are you"), .chat)
        XCTAssertEqual(IntentClassifier.classify("what is your name"), .chat)
    }

    func testTellMeAJokeRoutesToChat() {
        XCTAssertEqual(IntentClassifier.classify("tell me a joke"), .chat)
        XCTAssertEqual(IntentClassifier.classify("tell me about yourself"), .chat)
    }

    // MARK: - Task keywords

    func testActionKeywordsRouteToTask() {
        let cases = [
            "set a timer for 5 minutes",
            "calculate 6 * 7",
            "remind me to call mom tomorrow",
            "send a message to alex",
            "what is the weather today",
            "search for italian restaurants nearby",
            "open the calendar app",
            "fetch wikipedia summary for tokyo",
            "summarize this article",
        ]
        for msg in cases {
            XCTAssertEqual(IntentClassifier.classify(msg), .task,
                           "Expected '\(msg)' → task")
        }
    }

    func testFollowUpThenSetAlarmRoutesToTask() {
        // "then" looks like a follow-up but the message contains a task
        // keyword ("set an alarm"). Task wins, even with prior turn.
        XCTAssertEqual(
            IntentClassifier.classify("then set an alarm for 7am",
                                       hasPriorAssistantTurn: true),
            .task)
    }

    // MARK: - Follow-up markers

    func testColdStartShortQuestionRoutesToChat() {
        // Cold-start "why?" — short, not a substantive question, no task
        // keyword. Falls through to "<= 3 words → chat". Matches Android.
        XCTAssertEqual(IntentClassifier.classify("why?"), .chat)
    }

    func testFollowUpWithPriorTurnRoutesToChat() {
        XCTAssertEqual(
            IntentClassifier.classify("why?", hasPriorAssistantTurn: true),
            .chat)
        XCTAssertEqual(
            IntentClassifier.classify("what about it?", hasPriorAssistantTurn: true),
            .chat)
        XCTAssertEqual(
            IntentClassifier.classify("then what", hasPriorAssistantTurn: true),
            .chat)
    }

    // MARK: - Length heuristics

    func testShortMessageWithNoKeywordRoutesToChat() {
        XCTAssertEqual(IntentClassifier.classify("hmm interesting"), .chat,
                       "<= 3 words, no task keywords → chat")
    }

    func testLongQuestionRoutesToTask() {
        XCTAssertEqual(
            IntentClassifier.classify("could you help me figure something out?"),
            .task)
    }

    // MARK: - Default fallback

    func testLongDeclarativeWithoutKeywordsDefaultsToTask() {
        // Long, no clear keyword, no question mark → still task by default.
        // Better to plan unnecessarily than miss a request.
        XCTAssertEqual(
            IntentClassifier.classify("I want to buy a new pair of running shoes for the marathon"),
            .task)
    }
}

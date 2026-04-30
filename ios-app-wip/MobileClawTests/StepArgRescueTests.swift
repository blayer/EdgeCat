import XCTest
@testable import MobileClaw

final class StepArgRescueTests: XCTestCase {

    private let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 4; components.day = 27
        components.hour = 12; components.minute = 0
        // Concrete date — the components above are fully specified so
        // Calendar.date(from:) is guaranteed non-nil. Use the unix epoch
        // as the unreachable fallback to keep swiftlint happy.
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    // MARK: - Date-time normalization

    func testCanonicalDateTimePassesThrough() {
        let r = StepArgRescue.normalizeDateTime("2026-04-27T15:30", now: referenceDate)
        XCTAssertEqual(r, "2026-04-27T15:30")
    }

    func testTomorrowNinePm() {
        let r = StepArgRescue.normalizeDateTime("tomorrow at 9pm", now: referenceDate)
        XCTAssertEqual(r, "2026-04-28T21:00")
    }

    func testTodayElevenPm() {
        let r = StepArgRescue.normalizeDateTime("today at 11pm", now: referenceDate)
        XCTAssertEqual(r, "2026-04-27T23:00")
    }

    func testTodayNineThirtyAm() {
        let r = StepArgRescue.normalizeDateTime("today 9:30am", now: referenceDate)
        XCTAssertEqual(r, "2026-04-27T09:30")
    }

    func testTwentyFourHourTime() {
        let r = StepArgRescue.normalizeDateTime("today 14:30", now: referenceDate)
        XCTAssertEqual(r, "2026-04-27T14:30")
    }

    func testYesterdayMidnightHandlesAmTwelve() {
        let r = StepArgRescue.normalizeDateTime("yesterday 12am", now: referenceDate)
        XCTAssertEqual(r, "2026-04-26T00:00")
    }

    func testSpaceSeparatedDateTimeCoercesToTSeparator() {
        let r = StepArgRescue.normalizeDateTime("2026-04-27 14:30", now: referenceDate)
        XCTAssertEqual(r, "2026-04-27T14:30")
    }

    // MARK: - Phone normalization

    func testPhoneNumberStripsFormatting() {
        let r = StepArgRescue.normalizePhoneNumber("+1 (555) 123-4567", key: "phoneNumber")
        XCTAssertEqual(r, "+15551234567")
    }

    func testNonPhoneKeyLeavesValueAlone() {
        let r = StepArgRescue.normalizePhoneNumber("Alex (best friend)", key: "name")
        XCTAssertEqual(r, "Alex (best friend)")
    }

    // MARK: - Placeholder substitution

    func testPlaceholderReplacedWithStepOutput() {
        let r = StepArgRescue.substitutePlaceholders(
            "Output from s1",
            dependencies: ["s1": "the actual answer"])
        XCTAssertEqual(r, "the actual answer")
    }

    func testStepIdMentionInValueReplacesWithOutput() {
        let r = StepArgRescue.substitutePlaceholders(
            "use s1 result here",
            dependencies: ["s1": "fetched-data"])
        XCTAssertEqual(r, "fetched-data")
    }

    func testNoPlaceholderLeavesValueAlone() {
        let r = StepArgRescue.substitutePlaceholders(
            "literal value",
            dependencies: ["s1": "irrelevant"])
        XCTAssertEqual(r, "literal value")
    }

    // MARK: - URL extraction

    func testUrlArgExtractsFirstHttpsFromSearchResults() {
        // Mimics what search-web's output looks like when piped into a
        // chained fetch-web-content step via "Output from s1".
        let searchOutput = """
        Search results for: weather in Tokyo

        1. Tokyo weather - weather.com
           https://weather.com/tokyo
           Updated forecast.
        2. AccuWeather Tokyo
           https://accuweather.com/tokyo
        """
        let out = StepArgRescue.rescue(
            args: ["url": "Output from s1"],
            dependencies: ["s1": searchOutput],
            now: referenceDate)
        XCTAssertEqual(out["url"], "https://weather.com/tokyo")
    }

    func testUrlArgPassesCleanUrlThrough() {
        let out = StepArgRescue.rescue(
            args: ["url": "https://example.com/path"],
            dependencies: [:],
            now: referenceDate)
        XCTAssertEqual(out["url"], "https://example.com/path")
    }

    func testUrlArgHandlesJsonEscapedSlashes() {
        // Swift's JSONSerialization default emits `\/` for forward
        // slashes, so search-web's wrapped output looks like
        // `https:\/\/www.accuweather.com\/...`. Without un-escaping,
        // the regex captures only `https:` and fetch-web-content
        // fails with "invalid 'url' argument".
        let jsonOutput =
            #"{"results":"1. Tokyo - AccuWeather\n   https:\/\/www.accuweather.com\/en\/jp\/tokyo\n"}"#
        let out = StepArgRescue.rescue(
            args: ["url": "Output from s1"],
            dependencies: ["s1": jsonOutput],
            now: referenceDate)
        XCTAssertEqual(out["url"], "https://www.accuweather.com/en/jp/tokyo")
    }

    func testUrlArgHandlesJsonEscapedNewline() {
        // Real search-web output is JSON-serialized; newlines in the
        // formatted `results` field come through as the literal two-char
        // escape `\n`. The regex must stop at `\`, otherwise URL(string:)
        // rejects the trailing `\n` and fetch-web-content sees
        // `invalid 'url' argument`.
        let jsonOutput =
            #"{"status":"succeeded","results":"1. Tokyo\n   https://weather.com/tokyo\n   ..."}"#
        let out = StepArgRescue.rescue(
            args: ["url": "Output from s1"],
            dependencies: ["s1": jsonOutput],
            now: referenceDate)
        XCTAssertEqual(out["url"], "https://weather.com/tokyo")
    }

    func testUrlArgStripsTrailingPunctuation() {
        // URL captured from prose: "see https://example.com." → strip the period.
        let out = StepArgRescue.rescue(
            args: ["url": "Output from s1"],
            dependencies: ["s1": "Visit https://example.com."],
            now: referenceDate)
        XCTAssertEqual(out["url"], "https://example.com")
    }

    func testNonUrlArgIgnoresUrlExtraction() {
        // `text` arg should NOT have a URL scraped out of it.
        let out = StepArgRescue.rescue(
            args: ["text": "Visit https://example.com for more"],
            dependencies: [:],
            now: referenceDate)
        XCTAssertEqual(out["text"], "Visit https://example.com for more")
    }

    // MARK: - Full rescue pipeline

    func testRescueAppliesAllTransformsTogether() {
        let out = StepArgRescue.rescue(
            args: [
                "startTime": "tomorrow at 3pm",
                "phoneNumber": "+1 (555) 0123",
                "title": "use s1 result",
            ],
            dependencies: ["s1": "Team standup"],
            now: referenceDate)
        XCTAssertEqual(out["startTime"], "2026-04-28T15:00")
        XCTAssertEqual(out["phoneNumber"], "+15550123")
        XCTAssertEqual(out["title"], "Team standup")
    }
}

import XCTest
@testable import MobileClaw

final class FtsIndexTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        FtsIndex.shared.clear()
        // Allow the async clear to drain before tests query.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testRoundTripIndexAndSearch() async throws {
        let ep = Episode(id: "ep-fts-1",
                         userMessage: "find the closest pizza place near me",
                         goal: "locate pizza nearby",
                         skillsUsed: ["search-web"],
                         outcome: "success",
                         stepCount: 1,
                         finalOutput: "Found three pizza places")
        FtsIndex.shared.index(episode: ep)
        try await Task.sleep(nanoseconds: 100_000_000)

        let hits = FtsIndex.shared.search(query: "pizza", limit: 5)
        XCTAssertTrue(hits.contains("ep-fts-1"))
    }

    func testPrefixMatchAcrossTokens() async throws {
        let ep = Episode(id: "ep-prefix-1",
                         userMessage: "play some classical music",
                         goal: "music player",
                         skillsUsed: [], outcome: "success",
                         stepCount: 0, finalOutput: "")
        FtsIndex.shared.index(episode: ep)
        try await Task.sleep(nanoseconds: 100_000_000)

        // The implementation joins tokens with OR and adds prefix wildcards,
        // so "clas" should still surface "classical".
        let hits = FtsIndex.shared.search(query: "clas", limit: 5)
        XCTAssertTrue(hits.contains("ep-prefix-1"))
    }

    func testEmptyQueryReturnsEmpty() {
        XCTAssertEqual(FtsIndex.shared.search(query: "", limit: 5), [])
    }

    func testReindexOverwritesByEpisodeId() async throws {
        let id = "ep-reidx"
        FtsIndex.shared.index(episode: Episode(id: id, userMessage: "first version about cats",
                                               goal: "x", skillsUsed: [], outcome: "success",
                                               stepCount: 0, finalOutput: ""))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(FtsIndex.shared.search(query: "cats", limit: 5).contains(id))

        // Re-index the same id with new content; old terms should disappear.
        FtsIndex.shared.index(episode: Episode(id: id, userMessage: "second version about dogs",
                                               goal: "x", skillsUsed: [], outcome: "success",
                                               stepCount: 0, finalOutput: ""))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(FtsIndex.shared.search(query: "dogs", limit: 5).contains(id))
        XCTAssertFalse(FtsIndex.shared.search(query: "cats", limit: 5).contains(id))
    }

    func testClearRemovesAll() async throws {
        FtsIndex.shared.index(episode: Episode(id: "x", userMessage: "marker text",
                                               goal: "x", skillsUsed: [], outcome: "success",
                                               stepCount: 0, finalOutput: ""))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FtsIndex.shared.search(query: "marker", limit: 5).isEmpty)
        FtsIndex.shared.clear()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(FtsIndex.shared.search(query: "marker", limit: 5).isEmpty)
    }

    func testReservedCharactersDoNotCrash() async throws {
        // FTS5 has reserved chars (", *, etc). The implementation strips
        // double-quotes before building the MATCH expression. The strict
        // expectation here is just "the call doesn't crash and returns a
        // result"; an empty result is acceptable for a malformed query.
        FtsIndex.shared.index(episode: Episode(id: "ep-special",
                                               userMessage: "weather forecast",
                                               goal: "x", skillsUsed: [],
                                               outcome: "success",
                                               stepCount: 0, finalOutput: ""))
        try await Task.sleep(nanoseconds: 100_000_000)
        let hits = FtsIndex.shared.search(query: "\"weather\" forecast", limit: 5)
        XCTAssertNotNil(hits, "Sanitized double-quoted query should not crash")
    }
}

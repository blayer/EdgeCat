import XCTest
@testable import MobileClaw

/// Pure parsing/extraction coverage for SearchWebSkill + FetchWebContentSkill
/// (the network-side behavior is exercised by simulator smoke tests since CI
/// runners shouldn't depend on Google reachability).

final class WebSkillsTests: XCTestCase {

    // MARK: - SearchWebSkill: result parsing

    func testSearchWebParsesGoogleHtmlResults() {
        // A snippet of Google's mobile results layout — single <a><h3>
        // per result; that's the primary parser path.
        let html = """
        <html><body>
        <a href="https://en.wikipedia.org/wiki/Tokyo"><h3>Tokyo - Wikipedia</h3></a>
        <div class="VwiC3b">Tokyo, officially the Tokyo Metropolis, is the capital and most populous city of Japan.</div>
        <a href="https://www.lonelyplanet.com/japan/tokyo"><h3>Tokyo travel - Lonely Planet</h3></a>
        <a href="https://www.google.com/search?q=more"><h3>More results</h3></a>
        </body></html>
        """
        let results = SearchWebSkill.parseGoogleResults(html)
        XCTAssertEqual(results.count, 2,
                       "Two real results; the google.com link must be filtered out")
        XCTAssertEqual(results[0].title, "Tokyo - Wikipedia")
        XCTAssertEqual(results[0].url, "https://en.wikipedia.org/wiki/Tokyo")
        XCTAssertTrue(results[0].snippet.contains("capital"),
                      "Snippet should be picked up from the VwiC3b div")
        XCTAssertEqual(results[1].title, "Tokyo travel - Lonely Planet")
    }

    func testSearchWebFiltersOutGoogleInternalLinks() {
        let html = """
        <a href="https://www.google.com/search?q=foo"><h3>Search foo</h3></a>
        <a href="https://accounts.google.com/login"><h3>Sign in</h3></a>
        <a href="https://example.com"><h3>Real result</h3></a>
        """
        let results = SearchWebSkill.parseGoogleResults(html)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].url, "https://example.com")
    }

    func testSearchWebFormatTrucatesAt3000Chars() {
        let bigSnippet = String(repeating: "X", count: 800)
        let many = (0..<10).map {
            SearchWebSkill.WebSearchResult(
                title: "result \($0)",
                url: "https://example.com/\($0)",
                snippet: bigSnippet)
        }
        let formatted = SearchWebSkill.format(results: many)
        XCTAssertTrue(formatted.count <= 3050,
                      "Should truncate at ~3000 chars + truncation marker, got \(formatted.count)")
        XCTAssertTrue(formatted.contains("[truncated]"))
    }

    func testSearchWebRejectsMissingQuery() async {
        let result = await SearchWebSkill().run(args: [:])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("query") == true)
    }

    // MARK: - FetchWebContentSkill: HTML extraction

    func testFetchWebStripsScriptAndStyle() {
        let html = """
        <html><head><style>body { color: red; }</style></head>
        <body><script>alert('hi')</script><p>Hello world</p></body></html>
        """
        let text = FetchWebContentSkill.extractTextFromHtml(html)
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("color: red"))
        XCTAssertTrue(text.contains("Hello world"))
    }

    func testFetchWebPrefersMainContent() {
        let html = """
        <html><body>
        <nav>Home About Contact</nav>
        <header>Site title</header>
        <main><p>The actual article body goes here. It contains the real prose.</p></main>
        <footer>Copyright 2026</footer>
        </body></html>
        """
        let text = FetchWebContentSkill.extractTextFromHtml(html)
        XCTAssertTrue(text.contains("actual article body"))
        // nav/header/footer should be stripped before <main> selection,
        // and the <main> selection further isolates content from siblings.
        XCTAssertFalse(text.contains("Copyright"))
        XCTAssertFalse(text.contains("Home About Contact"))
    }

    func testFetchWebDecodesCommonEntities() {
        let html = "<p>Tom &amp; Jerry &lt;hi&gt; &nbsp;&quot;quoted&quot;</p>"
        let text = FetchWebContentSkill.extractTextFromHtml(html)
        XCTAssertTrue(text.contains("Tom & Jerry"))
        XCTAssertTrue(text.contains("<hi>"))
        XCTAssertTrue(text.contains("\"quoted\""))
    }

    func testFetchWebConvertsBlockTagsToNewlines() {
        // Use full sentences so each line survives the nav-run filter
        // (3+ consecutive short non-sentence lines get dropped — same
        // behavior Android's filter has).
        let html = "<p>First paragraph here.</p><p>Second paragraph follows.</p><div>And a third div block.</div>"
        let text = FetchWebContentSkill.extractTextFromHtml(html)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("First paragraph"))
        XCTAssertTrue(lines[2].contains("third div"))
    }

    func testFetchWebRendersTableCellContents() {
        // <td>/<th> get converted to tabs, then the per-line whitespace
        // collapse turns the tabs into single spaces (same behavior as
        // Android — the "scannable tabs" comment in the Kotlin source
        // is aspirational; the real value is that cells stay on one
        // line with delimiters, not literal tab survival).
        let html = "<table><tr><td>name column header</td><td>value column header</td></tr></table>"
        let text = FetchWebContentSkill.extractTextFromHtml(html)
        XCTAssertTrue(text.contains("name column header"))
        XCTAssertTrue(text.contains("value column header"))
    }

    // MARK: - FetchWebContentSkill: nav-menu run filter

    func testRemoveNavRunsDropsThreePlusShortLines() {
        let input = """
        About
        Contact
        Help
        This is the actual page content with a complete sentence.
        """
        let result = FetchWebContentSkill.removeNavRuns(input)
        XCTAssertFalse(result.contains("About"))
        XCTAssertFalse(result.contains("Contact"))
        XCTAssertFalse(result.contains("Help"))
        XCTAssertTrue(result.contains("actual page content"))
    }

    func testRemoveNavRunsKeepsTwoShortLines() {
        // Two short lines aren't a "menu run" — could just be a list.
        let input = """
        Yes
        No
        Another full sentence to anchor the content.
        """
        let result = FetchWebContentSkill.removeNavRuns(input)
        XCTAssertTrue(result.contains("Yes"))
        XCTAssertTrue(result.contains("No"))
    }

    func testRemoveNavRunsKeepsDataLines() {
        let input = """
        72°F
        Sunny
        15 mph
        70%
        """
        let result = FetchWebContentSkill.removeNavRuns(input)
        // All four are short but they all carry weather/data signals, so
        // the "isNavLike" filter must spare them even though they form a run.
        XCTAssertTrue(result.contains("72°F"))
        XCTAssertTrue(result.contains("15 mph"))
        XCTAssertTrue(result.contains("70%"))
    }

    func testFetchWebRejectsNonHttpUrl() async {
        let result = await FetchWebContentSkill().run(args: ["url": "file:///etc/passwd"])
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("invalid") == true)
    }
}

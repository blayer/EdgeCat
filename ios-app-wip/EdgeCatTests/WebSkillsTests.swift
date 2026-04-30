import XCTest
@testable import EdgeCat

/// Pure parsing/extraction coverage for SearchWebSkill + FetchWebContentSkill
/// (the network-side behavior is exercised by simulator smoke tests since CI
/// runners shouldn't depend on Google reachability).

final class WebSkillsTests: XCTestCase {

    // MARK: - SearchWebSkill: result parsing

    func testSearchWebParsesDuckDuckGoHtmlResults() {
        // DDG's `/html/` endpoint wraps each result link in
        // `<a class="result__a">`. URLs are routed through
        // `/l/?uddg=<encoded>` redirects which we unwrap.
        let html = """
        <html><body>
        <h2 class="result__title">
          <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FTokyo&rut=abc">
            Tokyo - Wikipedia
          </a>
        </h2>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FTokyo">
          Tokyo, officially the Tokyo Metropolis, is the capital and most populous city of Japan.
        </a>
        <h2 class="result__title">
          <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.lonelyplanet.com%2Fjapan%2Ftokyo">
            Tokyo travel - Lonely Planet
          </a>
        </h2>
        <a class="result__snippet" href="x">Tokyo travel guide.</a>
        </body></html>
        """
        let results = SearchWebSkill.parseDuckDuckGoResults(html)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "Tokyo - Wikipedia")
        XCTAssertEqual(results[0].url, "https://en.wikipedia.org/wiki/Tokyo")
        XCTAssertTrue(results[0].snippet.contains("capital"),
                      "Snippet should be picked up from result__snippet")
        XCTAssertEqual(results[1].title, "Tokyo travel - Lonely Planet")
        XCTAssertEqual(results[1].url, "https://www.lonelyplanet.com/japan/tokyo")
    }

    func testSearchWebUnwrapsDuckDuckGoRedirect() {
        let raw = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpath%3Fa%3D1&rut=xyz"
        let unwrapped = SearchWebSkill.unwrapDuckDuckGoRedirect(raw)
        XCTAssertEqual(unwrapped, "https://example.com/path?a=1")
    }

    func testSearchWebRedirectFallsBackToRawWhenNoUddg() {
        let raw = "https://example.com/direct"
        let unwrapped = SearchWebSkill.unwrapDuckDuckGoRedirect(raw)
        XCTAssertEqual(unwrapped, raw)
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

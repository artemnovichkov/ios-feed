import XCTest
@testable import iOSFeedBot

final class ArticleContentServiceTests: XCTestCase {
    func testExtractReadableTextRemovesScriptsStylesAndNavigation() {
        let html = """
        <html>
          <head>
            <style>.hidden { display: none; }</style>
            <script>window.analytics = true;</script>
          </head>
          <body>
            <nav>Home Archive About</nav>
            <article>
              <h1>Swift Concurrency in Practice</h1>
              <p>This article explains actor isolation.</p>
              <p>It also covers Sendable &amp; structured tasks.</p>
            </article>
            <footer>Subscribe now</footer>
          </body>
        </html>
        """

        let text = ArticleContentService.extractReadableText(from: html)

        XCTAssertTrue(text.contains("Swift Concurrency in Practice"))
        XCTAssertTrue(text.contains("This article explains actor isolation."))
        XCTAssertTrue(text.contains("It also covers Sendable & structured tasks."))
        XCTAssertFalse(text.contains("window.analytics"))
        XCTAssertFalse(text.contains(".hidden"))
        XCTAssertFalse(text.contains("Home Archive About"))
        XCTAssertFalse(text.contains("Subscribe now"))
    }

    func testExtractReadableTextNormalizesWhitespaceAndDecodesNumericEntities() {
        let html = """
        <main>
          <p>Swift&#39;s       type system</p>
          <p>uses &#x40;MainActor&nbsp;for UI isolation.</p>
        </main>
        """

        let text = ArticleContentService.extractReadableText(from: html)

        XCTAssertEqual(text, "Swift's type system uses @MainActor for UI isolation.")
    }

    func testProposalRawURLFindsLinkedSwiftEvolutionProposal() {
        let html = """
        <p>The review of <a href="https://github.com/swiftlang/swift-evolution/blob/main/proposals/0548-resign-remote-id.md">SE-0548</a> begins now.</p>
        <a href="https://github.com/swiftlang/swift-evolution/blob/main/process.md">process</a>
        """

        XCTAssertEqual(
            ArticleContentService.proposalRawURL(in: html),
            "https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/0548-resign-remote-id.md"
        )
        XCTAssertEqual(
            ArticleContentService.proposalRawURL(in: "<a href=\"https://github.com/swiftlang/swift-evolution/blob/main/proposals/testing/0029-add-issue-metadata.md\">ST-0029</a>"),
            "https://raw.githubusercontent.com/swiftlang/swift-evolution/main/proposals/testing/0029-add-issue-metadata.md"
        )
        XCTAssertNil(ArticleContentService.proposalRawURL(in: "<p>No proposal here</p>"))
    }

    func testPreviewCountsWordsAndCodeBlocksInsideArticle() throws {
        let body = String(repeating: "word ", count: 80)
        let html = """
        <html><body>
        <aside><pre>sidebar code</pre> lots of sidebar text</aside>
        <article class="post"><p>Opening line. \(body)</p><pre><code>let a = 1</code></pre><PRE>b</PRE></article>
        </body></html>
        """

        let preview = try XCTUnwrap(ArticleContentService.preview(fromHTML: html))

        XCTAssertEqual(preview.codeBlockCount, 2)
        XCTAssertEqual(preview.wordCount, 87)
        XCTAssertTrue(preview.excerpt.hasPrefix("Opening line."))
    }

    func testMainHTMLFallsBackToWholePageWhenArticleIsNearlyEmpty() {
        let html = "<article>tiny</article><div>\(String(repeating: "text ", count: 100))</div>"

        XCTAssertEqual(ArticleContentService.mainHTML(in: html), html)
    }

    func testPackageReleaseResolvesSwiftPackageIndexEntryToGitHubRepo() {
        let release = ArticleContentService.packageRelease(
            url: "https://swiftpackageindex.com/lyft/Hammer#releases",
            title: "Hammer - 2.0.0"
        )

        XCTAssertEqual(release, PackageRelease(owner: "lyft", repo: "Hammer", version: "2.0.0"))
        XCTAssertEqual(release?.candidateTags, ["2.0.0", "v2.0.0"])
        XCTAssertEqual(PackageRelease(owner: "o", repo: "r", version: "v3.0").candidateTags, ["v3.0", "3.0"])
    }

    func testPackageReleaseIgnoresOtherHostsBlogAndUnversionedTitles() {
        XCTAssertNil(ArticleContentService.packageRelease(url: "https://example.com/lyft/Hammer", title: "Hammer - 2.0.0"))
        XCTAssertNil(ArticleContentService.packageRelease(url: "https://swiftpackageindex.com/blog/post", title: "Update 2.0"))
        XCTAssertNil(ArticleContentService.packageRelease(url: "https://swiftpackageindex.com/lyft/Hammer", title: "Hammer"))
    }

    func testReleaseNotesReadsBodyAndSkipsErrorsAndEmptyNotes() {
        XCTAssertEqual(
            ArticleContentService.releaseNotes(fromJSON: #"{"tag_name": "2.0.0", "body": "Hammer 2.0 moves to async/await.\n"}"#),
            "Hammer 2.0 moves to async/await."
        )
        XCTAssertNil(ArticleContentService.releaseNotes(fromJSON: #"{"message": "Not Found"}"#))
        XCTAssertNil(ArticleContentService.releaseNotes(fromJSON: #"{"body": "  "}"#))
        XCTAssertNil(ArticleContentService.releaseNotes(fromJSON: "<html>rate limited</html>"))
    }
}

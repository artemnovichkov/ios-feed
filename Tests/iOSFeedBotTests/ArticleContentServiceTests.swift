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
}

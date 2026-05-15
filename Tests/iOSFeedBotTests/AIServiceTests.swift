import XCTest
@testable import iOSFeedBot

final class AIServiceTests: XCTestCase {
    func testSelectionPromptUsesNumberedCandidates() {
        let articles = [
            Article(
                title: "First Post",
                url: "https://example.com/first",
                description: "Feed summary",
                pubDate: Date()
            ),
            Article(
                title: "Second Post",
                url: "https://example.com/second",
                description: nil,
                pubDate: Date()
            )
        ]

        let prompt = AIService.buildSelectionPrompt(articles: articles)

        XCTAssertTrue(prompt.contains("1. First Post (https://example.com/first)"))
        XCTAssertTrue(prompt.contains("2. Second Post (https://example.com/second)"))
        XCTAssertTrue(prompt.contains("Feed description: Feed summary"))
        XCTAssertTrue(prompt.contains("ID: [The number of the selected article]"))
    }

    func testPostPromptUsesArticleContentAsSummarySource() {
        let article = Article(
            title: "Full Article",
            url: "https://example.com/full",
            description: "Short feed description",
            pubDate: Date()
        )

        let prompt = AIService.buildPostPrompt(
            article: article,
            content: "Full page text about the implementation details."
        )

        XCTAssertTrue(prompt.contains("Article content:\nFull page text about the implementation details."))
        XCTAssertTrue(prompt.contains("based on the article content"))
        XCTAssertFalse(prompt.contains("Short feed description"))
    }

    func testParseSelectedArticleID() {
        XCTAssertEqual(AIService.parseSelectedArticleID(from: "ID: 3"), 3)
        XCTAssertEqual(AIService.parseSelectedArticleID(from: "id: 12"), 12)
        XCTAssertNil(AIService.parseSelectedArticleID(from: "Article 3"))
    }

    func testParsePostReturnsContentAfterPostMarker() throws {
        let post = try AIService.parsePost(from: """
        POST:
        Article Title

        Summary text.

        #Swift #iOS #example
        """)

        XCTAssertEqual(post, "Article Title\n\nSummary text.\n\n#Swift #iOS #example")
    }
}

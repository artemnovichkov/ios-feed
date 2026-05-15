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
        XCTAssertTrue(prompt.contains("selectedArticleID"))
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

    func testOpenAIRequestEncodesStructuredResponseFormat() throws {
        let request = OpenAIRequest(
            messages: [.init(role: "user", content: "Select an article")],
            responseFormat: ResponseFormat(
                name: "article_selection",
                schema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "selectedArticleID": .object([
                            "type": .string("integer")
                        ])
                    ]),
                    "required": .array([.string("selectedArticleID")]),
                    "additionalProperties": .bool(false)
                ])
            )
        )

        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let responseFormat = json?["response_format"] as? [String: Any]
        let jsonSchema = responseFormat?["json_schema"] as? [String: Any]
        let schema = jsonSchema?["schema"] as? [String: Any]

        XCTAssertEqual(responseFormat?["type"] as? String, "json_schema")
        XCTAssertEqual(jsonSchema?["name"] as? String, "article_selection")
        XCTAssertEqual(jsonSchema?["strict"] as? Bool, true)
        XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
    }

    func testFormatPostBuildsTelegramPostFromStructuredOutput() {
        let post = AIService.formatPost(
            GeneratedPost(
                title: "Article Title",
                summary: "Summary text.",
                hashtags: ["Swift", "#iOS", "example"]
            )
        )

        XCTAssertEqual(post, "Article Title\n\nSummary text.\n\n#Swift #iOS #example")
    }
}

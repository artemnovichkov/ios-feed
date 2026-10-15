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
        XCTAssertTrue(prompt.contains("strictly technical channel"))
        XCTAssertTrue(prompt.contains("Never select marketing"))
        XCTAssertTrue(prompt.contains("Never select beginner explainers"))
        XCTAssertTrue(prompt.contains("score every item"))
        XCTAssertFalse(prompt.contains("already posted about these recently"))
    }

    func testSelectionPromptIncludesRecentPostsToAvoidRepeats() {
        let articles = [
            Article(
                title: "Fresh Post",
                url: "https://example.com/fresh",
                description: nil,
                pubDate: Date()
            )
        ]

        let prompt = AIService.buildSelectionPrompt(
            articles: articles,
            recentPosts: [
                RecentPost(title: "SomePackage - 4.11.0", hashtags: ["OpenSource", "Swift"]),
                RecentPost(title: "Another Article", hashtags: [])
            ]
        )

        XCTAssertTrue(prompt.contains("already posted about these recently"))
        XCTAssertTrue(prompt.contains("- SomePackage - 4.11.0 [#OpenSource #Swift]"))
        XCTAssertTrue(prompt.contains("- Another Article\n"))
        XCTAssertTrue(prompt.contains("first hashtag of either of the two newest"))
        XCTAssertTrue(prompt.contains("must not repeat itself"))
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

        XCTAssertTrue(prompt.contains("only a short description, not the full text"))

        XCTAssertTrue(prompt.contains("Content:\nFull page text about the implementation details."))
        XCTAssertTrue(prompt.contains("article/tutorial, an open source framework"))
        XCTAssertTrue(prompt.contains("For Swift Evolution proposals"))
        XCTAssertTrue(prompt.contains("Do NOT open with a template phrase"))
        XCTAssertTrue(prompt.contains("developer channel, not an ad"))
        XCTAssertTrue(prompt.contains("name the concrete APIs"))
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
                keyTakeaway: "Key point.",
                hashtags: ["Swift", "#iOS", "example"]
            )
        )

        XCTAssertEqual(post, "Article Title\n\nSummary text.\n\n💡 Key point.\n\n#Swift #iOS #example")
    }

    func testFormatPostAddsAuthorAndCapsHashtags() {
        let post = AIService.formatPost(
            GeneratedPost(
                title: "Title",
                summary: "Summary.",
                keyTakeaway: "",
                hashtags: ["SwiftUI", "swiftui", "Swift", "Xcode", "Testing"]
            ),
            author: "Natalia Panferova"
        )

        XCTAssertEqual(post, "Title\nby Natalia Panferova\n\nSummary.\n\n#SwiftUI #Swift #Xcode")
    }

    func testPostSchemaRestrictsHashtagsToTopicVocabulary() throws {
        let request = OpenAIRequest(
            messages: [],
            responseFormat: ResponseFormat(name: "telegram_post", schema: AIService.postSchemaForTesting)
        )
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        let schema = ((json?["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])?["schema"] as? [String: Any]
        let hashtags = (schema?["properties"] as? [String: Any])?["hashtags"] as? [String: Any]
        let items = hashtags?["items"] as? [String: Any]

        XCTAssertEqual(items?["enum"] as? [String], AIService.topicHashtags)
    }

    func testSanitizeHashtagStripsSpecialCharacters() {
        XCTAssertEqual(AIService.sanitizeHashtag("ios.dev"), "#iosdev")
        XCTAssertEqual(AIService.sanitizeHashtag("Swift UI"), "#SwiftUI")
        XCTAssertEqual(AIService.sanitizeHashtag("#swift-evolution"), "#swiftevolution")
        XCTAssertEqual(AIService.sanitizeHashtag("WWDC25"), "#WWDC25")
        XCTAssertEqual(AIService.sanitizeHashtag("#iOSDev"), "#iOSDev")
        XCTAssertEqual(AIService.sanitizeHashtag("..."), "")
    }

    func testFormatPostSanitizesHashtags() {
        let post = AIService.formatPost(
            GeneratedPost(
                title: "Title",
                summary: "Summary.",
                keyTakeaway: "",
                hashtags: ["Swift UI", "ios.dev", "#valid"]
            )
        )

        XCTAssertEqual(post, "Title\n\nSummary.\n\n#SwiftUI #iosdev #valid")
    }

    func testSelectionPromptMarksOfficialItems() {
        let articles = [
            Article(title: "SE-0548: resignRemoteID", url: "https://forums.swift.org/t/se-0548/89365", description: nil, pubDate: Date()),
            Article(title: "Community Post", url: "https://example.com/post", description: nil, pubDate: Date())
        ]

        let prompt = AIService.buildSelectionPrompt(articles: articles)

        XCTAssertTrue(prompt.contains("1. [Official] SE-0548: resignRemoteID (https://forums.swift.org/t/se-0548/89365)"))
        XCTAssertTrue(prompt.contains("2. Community Post (https://example.com/post)"))
    }

    func testPostPromptAsksForTakeawayOnlyWithFullText() {
        let article = Article(title: "T", url: "https://example.com", description: nil, pubDate: Date())

        let prompt = AIService.buildPostPrompt(article: article, content: String(repeating: "a", count: 2_000))

        XCTAssertTrue(prompt.contains("single most useful concrete thing"))
        XCTAssertFalse(prompt.contains("only a short description"))
    }

    func testSelectionPromptShowsPreviewAndOpeningOnlyWithoutDescription() {
        let articles = [
            Article(title: "No Description", url: "https://example.com/a", description: nil, pubDate: Date()),
            Article(title: "Described", url: "https://example.com/b", description: String(repeating: "d", count: 200), pubDate: Date())
        ]
        let previews = [
            "https://example.com/a": ArticlePreview(wordCount: 1200, codeBlockCount: 7, excerpt: "First words"),
            "https://example.com/b": ArticlePreview(wordCount: 300, codeBlockCount: 0, excerpt: "Other words")
        ]

        let prompt = AIService.buildSelectionPrompt(articles: articles, previews: previews)

        XCTAssertTrue(prompt.contains("Body: 1200 words, 7 code blocks\n   Opening: First words"))
        XCTAssertTrue(prompt.contains("Body: 300 words, 0 code blocks"))
        XCTAssertFalse(prompt.contains("Other words"))
    }

    func testChoiceMapsScoresToArticlesAndDropsUnknownIDs() throws {
        let articles = [
            Article(title: "A", url: "https://a.com", description: nil, pubDate: Date()),
            Article(title: "B", url: "https://b.com", description: nil, pubDate: Date())
        ]
        let selection = ArticleSelection(
            scores: [
                .init(id: 1, depth: 2, novelty: 2, usefulness: 2),
                .init(id: 2, depth: 5, novelty: 4, usefulness: 5),
                .init(id: 2, depth: 1, novelty: 1, usefulness: 1),
                .init(id: 9, depth: 5, novelty: 5, usefulness: 5)
            ],
            selectedArticleID: 2
        )

        let choice = try AIService.choice(from: selection, articles: articles)

        XCTAssertEqual(choice.article.url, "https://b.com")
        XCTAssertEqual(choice.scores.map(\.url), ["https://a.com", "https://b.com"])
        XCTAssertEqual(choice.scores.map(\.selected), [false, true])
        XCTAssertEqual(choice.scores.last?.total, 14)
        XCTAssertThrowsError(try AIService.choice(from: ArticleSelection(scores: [], selectedArticleID: 3), articles: articles))
    }

    func testSelectionSchemaLimitsScoresToOneThroughFive() throws {
        let data = try JSONEncoder().encode(AIService.selectionSchemaForTesting)
        let schema = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let scores = (schema?["properties"] as? [String: Any])?["scores"] as? [String: Any]
        let item = (scores?["items"] as? [String: Any])?["properties"] as? [String: Any]

        XCTAssertEqual((item?["depth"] as? [String: Any])?["enum"] as? [Int], [1, 2, 3, 4, 5])
        XCTAssertEqual(schema?["required"] as? [String], ["scores", "selectedArticleID"])
    }

    func testTopicsAreSanitizedDedupedAndCapped() {
        XCTAssertEqual(AIService.topics(["#SwiftUI", "swiftui", "Swift UI", "Xcode", "Testing"]), ["SwiftUI", "Xcode", "Testing"])
    }

    func testAuthorUsesPackageOwnerForSwiftPackageIndexAndHidesOfficial() {
        let spiMaintainers = "Dave Verwer and Sven A. Schmidt"
        XCTAssertEqual(FeedService.author(articleURL: "https://swiftpackageindex.com/pointfreeco/swift-sharing", blogAuthor: spiMaintainers), "pointfreeco")
        XCTAssertEqual(FeedService.author(articleURL: "https://swiftpackageindex.com/blog/some-post", blogAuthor: spiMaintainers), spiMaintainers)
        XCTAssertNil(FeedService.author(articleURL: "https://developer.apple.com/news/?id=abc", blogAuthor: "Apple"))
        XCTAssertNil(FeedService.author(articleURL: "https://www.swift.org/blog/post/", blogAuthor: "Apple"))
        XCTAssertEqual(FeedService.author(articleURL: "https://nilcoalescing.com/blog/Post", blogAuthor: "Natalia Panferova"), "Natalia Panferova")
    }
}

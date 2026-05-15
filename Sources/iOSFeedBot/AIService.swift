import Foundation
import iOSFeedMetrics
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AIError: Error {
    case invalidResponse(Int)
    case emptyResponse
    case invalidSelection
    case invalidStructuredOutput
}

final class AIService: @unchecked Sendable {
    private let metricsStore: SQLiteMetricsStore?
    private let runID: Int64?
    private let pricing: OpenAIPricing

    private static let maxArticleContentCharacters = 12_000
    private static let selectionSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "selectedArticleID": .object([
                "type": .string("integer")
            ])
        ]),
        "required": .array([.string("selectedArticleID")]),
        "additionalProperties": .bool(false)
    ])
    private static let postSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "title": .object([
                "type": .string("string")
            ]),
            "summary": .object([
                "type": .string("string")
            ]),
            "hashtags": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string")
                ])
            ])
        ]),
        "required": .array([.string("title"), .string("summary"), .string("hashtags")]),
        "additionalProperties": .bool(false)
    ])

    init(
        metricsStore: SQLiteMetricsStore? = nil,
        runID: Int64? = nil,
        pricing: OpenAIPricing = OpenAIPricing(inputPricePerMillionTokens: 0, outputPricePerMillionTokens: 0)
    ) {
        self.metricsStore = metricsStore
        self.runID = runID
        self.pricing = pricing
    }

    func selectArticle(from articles: [Article]) async throws -> Article {
        guard !articles.isEmpty else { throw AIError.emptyResponse }

        let prompt = Self.buildSelectionPrompt(articles: articles)
        let selection: ArticleSelection = try await sendPrompt(
            prompt,
            operation: "article_selection",
            responseFormat: ResponseFormat(name: "article_selection", schema: Self.selectionSchema)
        )

        guard articles.indices.contains(selection.selectedArticleID - 1) else {
            throw AIError.invalidSelection
        }

        return articles[selection.selectedArticleID - 1]
    }

    func generatePost(for article: Article, content: String) async throws -> String {
        let prompt = Self.buildPostPrompt(article: article, content: content)
        let response: GeneratedPost = try await sendPrompt(
            prompt,
            operation: "post_generation",
            responseFormat: ResponseFormat(name: "telegram_post", schema: Self.postSchema)
        )
        return Self.formatPost(response)
    }

    func generatePost(articles: [Article]) async throws -> (url: String, post: String) {
        guard !articles.isEmpty else { return ("", "") }

        let article = try await selectArticle(from: articles)
        let post = try await generatePost(for: article, content: article.description ?? "")
        return (article.url, post)
    }

    static func buildSelectionPrompt(articles: [Article]) -> String {
        let articleList = articles.enumerated().map { index, article in
            var text = "\(index + 1). \(article.title) (\(article.url))"
            if let description = article.description, !description.isEmpty {
                text += "\n   Feed description: \(description)"
            }
            return text
        }.joined(separator: "\n")

        return """
        I have a list of iOS development articles published in the last 24 hours:
        \(articleList)

        Please select the single most interesting and technically valuable article.
        Select only an article written in English.

        Instructions:
        - Return the selected article number in the selectedArticleID field.
        """
    }

    static func buildPostPrompt(article: Article, content: String) -> String {
        let articleContent = String(
            content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxArticleContentCharacters)
        )

        return """
        Generate a Telegram post for this iOS development article.

        Title: \(article.title)
        URL: \(article.url)

        Article content:
        \(articleContent)

        Instructions:
        - Return the article title in the title field.
        - Return a short summary (2-3 sentences) based on the article content in the summary field.
        - Return hashtags in the hashtags field, including a sanitized source domain hashtag.
        - Ensure hashtags are valid (alphanumeric, no dots/spaces/special characters).
        - Sanitize the SourceDomain hashtag (e.g., "iosdev.com" -> "#iosdev").
        """
    }

    static func formatPost(_ post: GeneratedPost) -> String {
        let hashtags = post.hashtags
            .map { hashtag in
                hashtag.hasPrefix("#") ? hashtag : "#\(hashtag)"
            }
            .joined(separator: " ")

        return """
        \(post.title)

        \(post.summary)

        \(hashtags)
        """
    }

    private func sendPrompt<Output: Decodable>(
        _ prompt: String,
        operation: String,
        responseFormat: ResponseFormat
    ) async throws -> Output {
        let startedAt = Date()
        let requestBody = OpenAIRequest(
            messages: [.init(role: "user", content: prompt)],
            responseFormat: responseFormat
        )
        let data = try JSONEncoder().encode(requestBody)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.openaiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOSFeedBot/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        
        do {
            let (responseData, urlResponse) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw AIError.invalidResponse(0)
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                throw AIError.invalidResponse(httpResponse.statusCode)
            }
            
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: responseData)
            guard let content = response.choices.first?.message.content else {
                throw AIError.emptyResponse
            }

            guard let outputData = content.data(using: .utf8) else {
                throw AIError.invalidStructuredOutput
            }

            let output = try JSONDecoder().decode(Output.self, from: outputData)
            recordAICall(
                operation: operation,
                usage: response.usage ?? OpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
                durationMilliseconds: startedAt.elapsedMilliseconds,
                status: "success",
                errorMessage: nil
            )
            return output
        } catch {
            recordAICall(
                operation: operation,
                usage: OpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0),
                durationMilliseconds: startedAt.elapsedMilliseconds,
                status: "failure",
                errorMessage: String(describing: error)
            )
            throw error
        }
    }

    private func recordAICall(
        operation: String,
        usage: OpenAIUsage,
        durationMilliseconds: Int,
        status: String,
        errorMessage: String?
    ) {
        guard let metricsStore, let runID else { return }
        try? metricsStore.recordAICall(
            runID: runID,
            operation: operation,
            model: Config.openaiModel,
            usage: usage,
            durationMilliseconds: durationMilliseconds,
            status: status,
            estimatedCostUSD: pricing.estimateCost(usage: usage),
            errorMessage: errorMessage
        )
    }
}

struct ArticleSelection: Codable, Sendable {
    let selectedArticleID: Int
}

struct GeneratedPost: Codable, Sendable {
    let title: String
    let summary: String
    let hashtags: [String]
}

struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
    let usage: OpenAIUsage?

    enum CodingKeys: String, CodingKey {
        case choices
        case usage
    }

    enum UsageCodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        choices = try container.decode([Choice].self, forKey: .choices)

        if container.contains(.usage) {
            let usageContainer = try container.nestedContainer(keyedBy: UsageCodingKeys.self, forKey: .usage)
            usage = OpenAIUsage(
                promptTokens: try usageContainer.decode(Int.self, forKey: .promptTokens),
                completionTokens: try usageContainer.decode(Int.self, forKey: .completionTokens),
                totalTokens: try usageContainer.decode(Int.self, forKey: .totalTokens)
            )
        } else {
            usage = nil
        }
    }
}

private extension Date {
    var elapsedMilliseconds: Int {
        Int(Date().timeIntervalSince(self) * 1000)
    }
}

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
    let model: String
    /// Tokens spent by this instance, for comparing models in dry runs.
    private(set) var usage = OpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)

    private static let maxArticleContentCharacters = 12_000
    private static let maxHashtags = 3
    /// Fixed vocabulary, so hashtags work as navigation across the channel.
    static let topicHashtags = [
        "SwiftUI", "UIKit", "Swift", "Concurrency", "SwiftEvolution", "Xcode", "BuildTools",
        "Testing", "Debugging", "Performance", "Architecture", "Persistence", "Networking",
        "Accessibility", "Animation", "AI", "Security", "OpenSource", "AppleNews",
        "macOS", "visionOS", "watchOS", "AppIntents", "Widgets", "StoreKit", "Graphics"
    ]
    /// Content shorter than this is a feed blurb, not the article: too thin for a takeaway.
    private static let minTakeawayContentCharacters = 1_500
    /// Share of a takeaway's significant words already in the summary that makes it a repeat.
    private static let maxTakeawayOverlap = 0.5
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "has", "have", "that", "this", "use", "uses", "from", "into",
        "under", "one", "its", "are", "was", "can", "not", "instead", "then", "when", "than", "you", "your"
    ]
    private static let scoreValue = JSONValue.object([
        "type": .string("integer"),
        "enum": .array((1...5).map(JSONValue.int))
    ])
    private static let selectionSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "scores": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("integer")]),
                        "depth": scoreValue,
                        "novelty": scoreValue,
                        "usefulness": scoreValue
                    ]),
                    "required": .array([.string("id"), .string("depth"), .string("novelty"), .string("usefulness")]),
                    "additionalProperties": .bool(false)
                ])
            ]),
            "selectedArticleID": .object([
                "type": .string("integer")
            ])
        ]),
        "required": .array([.string("scores"), .string("selectedArticleID")]),
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
            "keyTakeaway": .object([
                "type": .string("string")
            ]),
            "hashtags": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string"),
                    "enum": .array(topicHashtags.map(JSONValue.string))
                ])
            ])
        ]),
        "required": .array([.string("title"), .string("summary"), .string("keyTakeaway"), .string("hashtags")]),
        "additionalProperties": .bool(false)
    ])

    static var postSchemaForTesting: JSONValue { postSchema }
    static var selectionSchemaForTesting: JSONValue { selectionSchema }

    init(
        metricsStore: SQLiteMetricsStore? = nil,
        runID: Int64? = nil,
        pricing: OpenAIPricing = OpenAIPricing(inputPricePerMillionTokens: 0, outputPricePerMillionTokens: 0),
        model: String = Config.openaiModel
    ) {
        self.metricsStore = metricsStore
        self.runID = runID
        self.pricing = pricing
        self.model = model
    }

    func selectArticle(
        from articles: [Article],
        recentPosts: [RecentPost] = [],
        previews: [String: ArticlePreview] = [:]
    ) async throws -> ArticleChoice {
        guard !articles.isEmpty else { throw AIError.emptyResponse }

        let prompt = Self.buildSelectionPrompt(articles: articles, recentPosts: recentPosts, previews: previews)
        let selection: ArticleSelection = try await sendPrompt(
            prompt,
            operation: "article_selection",
            responseFormat: ResponseFormat(name: "article_selection", schema: Self.selectionSchema)
        )
        return try Self.choice(from: selection, articles: articles)
    }

    /// Maps the model's 1-based IDs back to articles; scores with unknown IDs are dropped.
    static func choice(from selection: ArticleSelection, articles: [Article]) throws -> ArticleChoice {
        guard articles.indices.contains(selection.selectedArticleID - 1) else {
            throw AIError.invalidSelection
        }
        let article = articles[selection.selectedArticleID - 1]
        var seen = Set<Int>()
        let scores = selection.scores
            .filter { articles.indices.contains($0.id - 1) && seen.insert($0.id).inserted }
            .map { score in
                let candidate = articles[score.id - 1]
                return CandidateScore(
                    url: candidate.url,
                    title: candidate.title,
                    depth: score.depth,
                    novelty: score.novelty,
                    usefulness: score.usefulness,
                    selected: score.id == selection.selectedArticleID
                )
            }
        return ArticleChoice(article: article, scores: scores)
    }

    func generatePost(for article: Article, content: String) async throws -> PostDraft {
        let prompt = Self.buildPostPrompt(article: article, content: content)
        let response: GeneratedPost = try await sendPrompt(
            prompt,
            operation: "post_generation",
            responseFormat: ResponseFormat(name: "telegram_post", schema: Self.postSchema)
        )
        return PostDraft(text: Self.formatPost(response, author: article.author), hashtags: Self.topics(response.hashtags))
    }

    static func buildSelectionPrompt(
        articles: [Article],
        recentPosts: [RecentPost] = [],
        previews: [String: ArticlePreview] = [:]
    ) -> String {
        let articleList = articles.enumerated().map { index, article in
            let marker = ArticleFilter.isOfficial(article.url) ? "[Official] " : ""
            var text = "\(index + 1). \(marker)\(article.title) (\(article.url))"
            let description = article.description ?? ""
            if !description.isEmpty {
                text += "\n   Feed description: \(description)"
            }
            if let preview = previews[article.url] {
                text += "\n   Body: \(preview.wordCount) words, \(preview.codeBlockCount) code blocks"
                // The excerpt costs tokens and mostly repeats the feed description when there is one.
                if description.count < 150 {
                    text += "\n   Opening: \(preview.excerpt)"
                }
            }
            return text
        }.joined(separator: "\n")

        var recentSection = ""
        if !recentPosts.isEmpty {
            let recentList = recentPosts.map { post in
                let topics = post.hashtags.map { "#\($0)" }.joined(separator: " ")
                return topics.isEmpty ? "- \(post.title)" : "- \(post.title) [\(topics)]"
            }.joined(separator: "\n")
            recentSection = """


            The channel has already posted about these recently, newest first, with topic hashtags where known:
            \(recentList)
            """
        }

        return """
        I have a list of iOS development content published in the last 24 hours (articles, open source releases, framework updates):
        \(articleList)\(recentSection)

        Please select the single most interesting and technically valuable item.
        Select only an item written in English.

        Instructions:
        - This is a strictly technical channel for engineers. Select content about building software: APIs, frameworks, language features, tooling, debugging, performance, testing, or architecture.
        - The item must be about Apple platform development (iOS, iPadOS, macOS, watchOS, tvOS, visionOS) or the Swift language and its ecosystem. The list is built from iOS blogs, but the same authors also publish about other stacks — never select an item about Elixir, Rust, Go, Android, web frontend or backend, or any other ecosystem, no matter how technically strong it is.
        - Never select marketing, ASO, growth, monetization, pricing, revenue, ads, affiliate, sponsorship, or general business/founder content, even when it is aimed at iOS developers. The same applies to career advice, hiring posts, and conference announcements.
        - Never select an item about the same library, project, or topic as a recent post above — the channel must not repeat itself.
        - Vary topics day to day: avoid an item whose main subject matches the first hashtag of either of the two newest recent posts (e.g. no SwiftUI layout post right after a SwiftUI post), unless nothing else is substantive.
        - Never select beginner explainers of well-known basics: property wrappers and @State vs @Binding, .task vs .onAppear, what async/await or MVVM is, how to make a list or a button, intro tutorials to long-established APIs. The audience is experienced Apple platform engineers who already know this.
        - Feed descriptions are written by the authors and often read like marketing. Judge by substance, not by the length of a feature list.
        - Prefer items that go deep — code, implementation details, measurements, non-obvious gotchas — over news roundups, link digests, and opinion pieces. "Body" gives the length and number of code blocks of the actual page when it could be fetched: a few hundred words with no code is rarely deep, but a long page can still be shallow, so read the title and opening too.
        - Prefer articles and tutorials with real insight over routine package version bumps. Select a package release only if it is a major, genuinely noteworthy update.
        - Items marked [Official] come from Apple or the Swift project. Prefer one over community articles when it is substantive for engineers: a Swift Evolution proposal in review or accepted, a new or changed API, a new documentation article or sample code, a platform requirement or deprecation developers must act on. Do not prefer bare release entries (beta/RC build numbers, "App Store Connect Update") or event and promo announcements.
        - If every item is non-technical, select the one closest to hands-on Apple platform engineering.

        Output:
        - In the scores field, score every item in the list, including ones you would never select, from 1 to 5 on:
          - depth: 1 = surface overview or news blurb, 5 = implementation details, internals, code, or measurements.
          - novelty: 1 = basics covered everywhere, 5 = new API, technique, or non-obvious finding.
          - usefulness: 1 = nothing an engineer can apply, 5 = directly applicable in a real app.
        - Return the selected item number in the selectedArticleID field: the best item by these scores that also follows every rule above. The rules override the scores.
        """
    }

    static func buildPostPrompt(article: Article, content: String) -> String {
        let articleContent = String(
            content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxArticleContentCharacters)
        )
        // A made-up takeaway is worse than none: only ask for one when the full text is there.
        let takeawayInstruction = articleContent.count < minTakeawayContentCharacters
            ? "The content above is only a short description, not the full text: return an empty string in the keyTakeaway field."
            : "Return one sentence of at most 25 words in the keyTakeaway field: the single most useful concrete thing a reader learns — a non-obvious behavior, a gotcha, a measurement, or the exact API to reach for. It must add something the summary doesn't already say, not restate it in other words, and must be stated in the content, not inferred. For a package release, prefer a breaking change, a migration step, or a new API from the release notes. No generic statements like \"this improves code quality\". If the content has no such concrete point, return an empty string."

        return """
        Generate a Telegram post for this iOS development content.

        Title: \(article.title)
        URL: \(article.url)

        Content:
        \(articleContent)

        Instructions:
        - Determine whether this is an article/tutorial, an open source framework/library release, an official Apple announcement, or a Swift Evolution proposal.
        - Return the title in the title field.
        - Return a short summary in the summary field: at most 2 sentences and 50 words. Pick the one or two points that matter most instead of listing every API the content mentions.
          - Write naturally and engagingly — vary the sentence structure each time.
          - Do NOT open with a template phrase like "The author introduces", "The article discusses", "This article covers", or any fixed formula. Lead with what's actually interesting: the problem solved, the technique used, the key insight, or what makes this worth reading.
          - For frameworks/libraries: focus on what it does, what problem it solves, or what changed in this release.
          - For package releases with release notes: say what changed in this version and why it matters, not just what the package is.
          - Never mention package metadata: license, stars, number of dependencies, libraries, or executables, or when it was released.
          - For Swift Evolution proposals: explain what the proposal changes in the language or library, and mention its status (in review until a date, accepted, accepted with modifications).
          - Stay technical and factual: name the concrete APIs, types, tools, or techniques the content actually covers.
        - In the summary and keyTakeaway, wrap code in backticks: API names, types, methods, properties, keywords, file names, and commands (e.g. `URL.path`, `path(percentEncoded:)`, `AGENTS.md`). Do not use backticks in the title or for plain product or framework names like SwiftUI or Xcode.
        - \(takeawayInstruction)
        - This is a developer channel, not an ad. Do NOT use promotional or hype language ("unlock", "secrets", "game-changing", "must-read", "packed with insights", "supercharge", "take your app to the next level"), and do NOT end with a call to action telling the reader to read, dive in, or check it out.
        - Never use "we", "our", or first-person plural — the channel is sharing, not authoring.
        - Return 1 to 3 hashtags in the hashtags field, most relevant first, picked from the allowed values only. Tag the main subject, not every topic mentioned in passing.
          - "Persistence" covers SwiftData, Core Data, CloudKit, and file storage. "BuildTools" covers SwiftPM, Bazel, CI, and build systems. "AppleNews" is for official Apple announcements, requirements, and deprecations. "OpenSource" is for library and package releases.
          - "AppIntents" covers App Intents, Siri, Shortcuts, and Spotlight. "Widgets" covers WidgetKit, Live Activities, and Control Center controls. "Graphics" covers Metal, RealityKit, Core Animation, Core Image, and shaders. Use a platform tag (macOS, visionOS, watchOS) only when the content is specific to that platform.
        """
    }

    static func sanitizeHashtag(_ hashtag: String) -> String {
        let raw = hashtag.hasPrefix("#") ? String(hashtag.dropFirst()) : hashtag
        let sanitized = raw.unicodeScalars
            .filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0) }
            .map { String($0) }
            .joined()
        return sanitized.isEmpty ? "" : "#\(sanitized)"
    }

    /// Sanitized, deduplicated hashtags without "#", capped and in the model's relevance order.
    static func topics(_ hashtags: [String]) -> [String] {
        var seen = Set<String>()
        return hashtags
            .map { String(sanitizeHashtag($0).dropFirst()) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(maxHashtags)
            .map { $0 }
    }

    /// The model often restates the summary despite the prompt: a takeaway whose words are
    /// mostly in the summary already adds nothing, so it is dropped.
    static func isRedundant(takeaway: String, summary: String) -> Bool {
        let takeawayWords = significantWords(in: takeaway)
        guard !takeawayWords.isEmpty else { return true }
        let shared = takeawayWords.intersection(significantWords(in: summary))
        return Double(shared.count) / Double(takeawayWords.count) >= maxTakeawayOverlap
    }

    private static func significantWords(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

        static func formatPost(_ post: GeneratedPost, author: String? = nil) -> String {
        let hashtags = topics(post.hashtags).map { "#\($0)" }.joined(separator: " ")

        var lines = [post.title]
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            lines.append("by \(author)")
        }
        lines += ["", post.summary]
        let takeaway = post.keyTakeaway.trimmingCharacters(in: .whitespacesAndNewlines)
        if !takeaway.isEmpty && !isRedundant(takeaway: takeaway, summary: post.summary) {
            lines += ["", "💡 \(takeaway)"]
        }
        lines += ["", hashtags]
        return lines.joined(separator: "\n")
    }

    private func sendPrompt<Output: Decodable>(
        _ prompt: String,
        operation: String,
        responseFormat: ResponseFormat
    ) async throws -> Output {
        let startedAt = Date()
        let requestBody = OpenAIRequest(
            model: model,
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
            if let callUsage = response.usage {
                usage = OpenAIUsage(
                    promptTokens: usage.promptTokens + callUsage.promptTokens,
                    completionTokens: usage.completionTokens + callUsage.completionTokens,
                    totalTokens: usage.totalTokens + callUsage.totalTokens
                )
            }
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
            model: model,
            usage: usage,
            durationMilliseconds: durationMilliseconds,
            status: status,
            estimatedCostUSD: pricing.estimateCost(usage: usage),
            errorMessage: errorMessage
        )
    }
}

struct ArticleSelection: Codable, Sendable {
    struct Score: Codable, Sendable {
        let id: Int
        let depth: Int
        let novelty: Int
        let usefulness: Int
    }

    let scores: [Score]
    let selectedArticleID: Int
}

struct ArticleChoice: Sendable {
    let article: Article
    let scores: [CandidateScore]
}

struct PostDraft: Sendable {
    let text: String
    /// Topic hashtags without "#", stored to vary topics in later selections.
    let hashtags: [String]
}

struct RecentPost: Sendable {
    let title: String
    let hashtags: [String]
}

struct GeneratedPost: Codable, Sendable {
    let title: String
    let summary: String
    let keyTakeaway: String
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

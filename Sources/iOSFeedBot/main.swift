import Foundation
import iOSFeedMetrics

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func appendUTMParameters(to urlString: String) -> String {
    guard var components = URLComponents(string: urlString) else { return urlString }
    
    var queryItems = components.queryItems ?? []
    let utmItems = [
        URLQueryItem(name: "utm_source", value: "telegram"),
        URLQueryItem(name: "utm_medium", value: "channel"),
        URLQueryItem(name: "utm_campaign", value: "ios_daily")
    ]
    
    // Avoid duplicates if they already exist
    for item in utmItems {
        if !queryItems.contains(where: { $0.name == item.name }) {
            queryItems.append(item)
        }
    }
    
    components.queryItems = queryItems
    return components.url?.absoluteString ?? urlString
}

/// Hyperlinks the first line (the title) and escapes the rest for Telegram HTML.
func formatTelegramPost(_ post: String, url: String) -> String {
    var lines = post.components(separatedBy: .newlines)
    guard !lines.isEmpty else { return post }
    lines[0] = "<a href=\"\(appendUTMParameters(to: url))\"><b>\(escapeHTML(lines[0]))</b></a>"
    for i in 1..<lines.count {
        lines[i] = escapeHTML(lines[i])
    }
    return lines.joined(separator: "\n")
}

/// Runs selection and generation for each model on the same candidate pool and prints
/// the results. Nothing is posted and no metrics are recorded.
func runDryRun(
    models: [String],
    candidates: [Article],
    recentPosts: [RecentPost],
    previews: [String: ArticlePreview]
) async {
    print("\nCandidates (\(candidates.count)):")
    for (index, article) in candidates.enumerated() {
        let body = previews[article.url].map { " [\($0.wordCount)w, \($0.codeBlockCount) code]" } ?? ""
        print("\(index + 1). \(article.title)\(body) — \(article.url)")
    }

    let articleContentService = ArticleContentService()
    var contentCache: [String: String] = [:]
    for model in models {
        print("\n===== \(model) =====")
        let aiService = AIService(model: model)
        let startedAt = Date()
        do {
            let choice = try await aiService.selectArticle(from: candidates, recentPosts: recentPosts, previews: previews)
            let article = choice.article
            print("Top scores (depth/novelty/usefulness):")
            for score in choice.scores.sorted(by: { $0.total > $1.total }).prefix(5) {
                print("  \(score.selected ? "*" : " ") \(score.depth)/\(score.novelty)/\(score.usefulness) \(score.title)")
            }
            let content: String
            if let cached = contentCache[article.url] {
                content = cached
            } else {
                content = await articleContentService.fetchContent(for: article.url) ?? article.description ?? ""
                contentCache[article.url] = content
            }
            let post = try await aiService.generatePost(for: article, content: content)
            print("Selected: \(article.url)\n")
            print(post.text)
            print("\n[tokens in \(aiService.usage.promptTokens), out \(aiService.usage.completionTokens), \(elapsedMilliseconds(since: startedAt)) ms]")
        } catch {
            print("Failed: \(error)")
        }
    }
}

func elapsedMilliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1000)
}

func measure<T>(
    _ name: String,
    metricsStore: SQLiteMetricsStore?,
    runID: Int64?,
    operation: () async throws -> T
) async throws -> T {
    let startedAt = Date()
    do {
        let result = try await operation()
        if let metricsStore, let runID {
            try? metricsStore.recordStep(
                runID: runID,
                name: name,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                status: "success"
            )
        }
        return result
    } catch {
        if let metricsStore, let runID {
            try? metricsStore.recordStep(
                runID: runID,
                name: name,
                durationMilliseconds: elapsedMilliseconds(since: startedAt),
                status: "failure",
                errorMessage: String(describing: error)
            )
        }
        throw error
    }
}

func publish(
    method: String,
    article: Article,
    hashtags: [String],
    telegramService: TelegramService,
    metricsStore: SQLiteMetricsStore?,
    runID: Int64?,
    send: () async throws -> Int?
) async throws {
    do {
        let messageID = try await measure("telegram_publish", metricsStore: metricsStore, runID: runID, operation: send)
        if let metricsStore, let runID {
            try? metricsStore.recordTelegramPost(
                runID: runID,
                messageID: messageID,
                method: method,
                articleURL: article.url,
                title: article.title,
                hashtags: hashtags,
                status: "success"
            )
        }
        if let messageID {
            let subscriberCount = try? await telegramService.getChatMemberCount()
            try? metricsStore?.recordEngagement(
                messageID: messageID,
                subscriberCount: subscriberCount,
                reactionCount: nil,
                detailsJSON: nil
            )
        }
    } catch {
        if let metricsStore, let runID {
            try? metricsStore.recordTelegramPost(
                runID: runID,
                messageID: nil,
                method: method,
                articleURL: article.url,
                title: article.title,
                status: "failure",
                errorMessage: String(describing: error)
            )
        }
        throw error
    }
}

let runStartedAt = Date()
var metricsStore: SQLiteMetricsStore?
var runID: Int64?
var articlesFound = 0
var selectedArticleForMetrics: Article?

/// `--dry-run [--models a,b]`: compare models on today's candidates without posting.
let isDryRun = CommandLine.arguments.contains("--dry-run")
let dryRunModels = CommandLine.arguments.firstIndex(of: "--models")
    .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    .map { $0.split(separator: ",").map(String.init) } ?? [Config.openaiModel]
/// `--days-ago N` (dry runs only): replay the candidate pool as it looked N days ago.
let dryRunDaysAgo = isDryRun
    ? CommandLine.arguments.firstIndex(of: "--days-ago")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Int(CommandLine.arguments[$0 + 1]) : nil } ?? 0
    : 0
let referenceDate = Date().addingTimeInterval(-Double(dryRunDaysAgo) * 24 * 60 * 60)

do {
    // First validate config
    Config.validate(requireTelegram: !isDryRun)

    metricsStore = try? SQLiteMetricsStore(path: Config.metricsDatabasePath)
    // Dry runs read post history for dedupe but leave no run behind.
    runID = isDryRun ? nil : try? metricsStore?.startRun(startedAt: runStartedAt)
    
    let directoryService = DirectoryService()
    let feedService = FeedService()
    let aiService = AIService(
        metricsStore: metricsStore,
        runID: runID,
        pricing: OpenAIPricing(
            inputPricePerMillionTokens: Config.openAIInputPricePerMillionTokens,
            outputPricePerMillionTokens: Config.openAIOutputPricePerMillionTokens
        )
    )
    let articleContentService = ArticleContentService()
    let metadataService = MetadataService()
    let telegramService = TelegramService()
    
    let postHistory = ((try? metricsStore?.telegramPosts(limit: 300)) ?? [])
        .filter { $0.status == "success" }

    // Exactly one post per day: extra runs (retries, manual launches) become no-ops.
    let startOfToday = Calendar.current.startOfDay(for: Date())
    if !isDryRun, postHistory.contains(where: { $0.postedAt >= startOfToday }) {
        print("Already posted today — skipping.")
        if let metricsStore, let runID {
            try? metricsStore.finishRun(
                id: runID,
                status: "success",
                durationMilliseconds: elapsedMilliseconds(since: runStartedAt),
                articlesFound: 0,
                selectedArticleTitle: nil,
                selectedArticleURL: nil,
                errorMessage: nil
            )
        }
        Foundation.exit(0)
    }

    print("Fetching blog directory...")
    let blogs = try await measure("directory_fetch", metricsStore: metricsStore, runID: runID) {
        try await directoryService.fetchBlogs()
    }

    print("Fetching recent articles from \(blogs.count) feeds...")
    // Fetch a 72h window so there is a backfill pool when everything fresh was already posted.
    let articles = try await measure("feed_fetch", metricsStore: metricsStore, runID: runID) {
        await feedService.fetchAllRecent(blogs: blogs, maxAge: Double(72 + dryRunDaysAgo * 24) * 60 * 60)
    }.filter { $0.pubDate <= referenceDate }
    let last24Hours = referenceDate.addingTimeInterval(-24 * 60 * 60)
    let freshArticles = articles.filter { $0.pubDate > last24Hours }
    articlesFound = freshArticles.count
    print("Found \(freshArticles.count) articles in the last 24h (\(articles.count) in the last 72h).")

    if articles.isEmpty {
        print("No new articles found.")
        if let metricsStore, let runID {
            try? metricsStore.finishRun(
                id: runID,
                status: "success",
                durationMilliseconds: elapsedMilliseconds(since: runStartedAt),
                articlesFound: articlesFound,
                selectedArticleTitle: nil,
                selectedArticleURL: nil,
                errorMessage: nil
            )
        }
        Foundation.exit(0)
    }
    
    print("Filtering out previously posted articles...")
    let postedURLs = Set(postHistory.compactMap { $0.articleURL }.map(ArticleFilter.normalizeURL))
    let repostCutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    let recentlyPostedURLs = Set(
        postHistory
            .filter { $0.postedAt > repostCutoff }
            .compactMap { $0.articleURL }
            .map(ArticleFilter.normalizeURL)
    )

    let (tierCandidates, tier) = ArticleFilter.candidates(
        freshArticles: freshArticles,
        allArticles: articles,
        postedURLs: postedURLs,
        recentlyPostedURLs: recentlyPostedURLs
    )
    switch tier {
    case .fresh:
        print("\(tierCandidates.count) unique candidates from the last 24h.")
    case .backfill:
        print("Nothing unposted in the last 24h — falling back to the 72h window (\(tierCandidates.count) candidates).")
    case .repost:
        print("Nothing unposted in the last 72h — allowing reposts older than 30 days (\(tierCandidates.count) candidates).")
    }

    let sourceCooldown = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    let recentSources = Set(
        postHistory
            .filter { $0.postedAt > sourceCooldown }
            .compactMap { $0.articleURL }
            .map(ArticleFilter.sourceKey)
    )
    let candidates = ArticleFilter.diverseCandidates(tierCandidates, excludingSources: recentSources)
    print("\(candidates.count) candidates after excluding blogs posted in the last 7 days.")

    if candidates.isEmpty {
        print("No new unique articles found.")
        if let metricsStore, let runID {
            try? metricsStore.finishRun(
                id: runID,
                status: "success",
                durationMilliseconds: elapsedMilliseconds(since: runStartedAt),
                articlesFound: articlesFound,
                selectedArticleTitle: nil,
                selectedArticleURL: nil,
                errorMessage: nil
            )
        }
        Foundation.exit(0)
    }

    let recentPostWindow = Date().addingTimeInterval(-14 * 24 * 60 * 60)
    // postHistory is newest first, which the selection prompt relies on for topic variety.
    let recentPosts = postHistory
        .filter { $0.postedAt > recentPostWindow }
        .compactMap { post in post.title.map { RecentPost(title: $0, hashtags: post.hashtags) } }

    print("Fetching candidate previews...")
    let previews = try await measure("candidate_preview_fetch", metricsStore: metricsStore, runID: runID) {
        await articleContentService.fetchPreviews(for: candidates)
    }
    print("Fetched \(previews.count) of \(min(candidates.count, ArticleContentService.maxPreviews)) candidate pages.")

    if isDryRun {
        await runDryRun(models: dryRunModels, candidates: candidates, recentPosts: recentPosts, previews: previews)
        Foundation.exit(0)
    }

    print("Selecting best article...")
    let choice = try await measure("article_selection", metricsStore: metricsStore, runID: runID) {
        try await aiService.selectArticle(from: candidates, recentPosts: recentPosts, previews: previews)
    }
    let selectedArticle = choice.article
    selectedArticleForMetrics = selectedArticle
    if let metricsStore, let runID {
        try? metricsStore.recordCandidateScores(runID: runID, scores: choice.scores)
    }

    print("Fetching selected article content...")
    let articleContent = try await measure("article_content_fetch", metricsStore: metricsStore, runID: runID) {
        await articleContentService.fetchContent(for: selectedArticle.url)
            ?? selectedArticle.description
            ?? ""
    }

    print("Generating post from article content...")
    let post = try await measure("post_generation", metricsStore: metricsStore, runID: runID) {
        try await aiService.generatePost(for: selectedArticle, content: articleContent)
    }

    if post.text.isEmpty {
         print("AI failed to generate a post.")
        if let metricsStore, let runID {
            try? metricsStore.finishRun(
                id: runID,
                status: "failure",
                durationMilliseconds: elapsedMilliseconds(since: runStartedAt),
                articlesFound: articlesFound,
                selectedArticleTitle: selectedArticleForMetrics?.title,
                selectedArticleURL: selectedArticleForMetrics?.url,
                errorMessage: "AI failed to generate a post."
            )
        }
         Foundation.exit(0)
    }
    
    let formattedPost = formatTelegramPost(post.text, url: selectedArticle.url)
    
    print("Fetching OG image...")
    let ogImageURL = try await measure("og_image_fetch", metricsStore: metricsStore, runID: runID) {
        await metadataService.fetchOGImageURL(for: selectedArticle.url)
    }
    
    if let ogImageURL = ogImageURL {
        print("Publishing to Telegram with image...")
        do {
            try await publish(method: "sendPhoto", article: selectedArticle, hashtags: post.hashtags, telegramService: telegramService, metricsStore: metricsStore, runID: runID) {
                try await telegramService.sendPhoto(url: ogImageURL, caption: formattedPost)
            }
        } catch {
            // Telegram fetches the image itself and fails on blocked or broken URLs: post without it.
            print("Publishing with image failed (\(error)) — retrying without image...")
            try await publish(method: "sendMessage", article: selectedArticle, hashtags: post.hashtags, telegramService: telegramService, metricsStore: metricsStore, runID: runID) {
                try await telegramService.sendMessage(formattedPost)
            }
        }
    } else {
        print("Publishing to Telegram (no image found)...")
        try await publish(method: "sendMessage", article: selectedArticle, hashtags: post.hashtags, telegramService: telegramService, metricsStore: metricsStore, runID: runID) {
            try await telegramService.sendMessage(formattedPost)
        }
    }

    if let metricsStore, let runID {
        try? metricsStore.finishRun(
            id: runID,
            status: "success",
            durationMilliseconds: elapsedMilliseconds(since: runStartedAt),
            articlesFound: articlesFound,
            selectedArticleTitle: selectedArticleForMetrics?.title,
            selectedArticleURL: selectedArticleForMetrics?.url,
            errorMessage: nil
        )
    }
    
    print("Done!")
} catch {
    if let metricsStore, let runID {
        try? metricsStore.finishRun(
            id: runID,
            status: "failure",
            durationMilliseconds: elapsedMilliseconds(since: runStartedAt),
            articlesFound: articlesFound,
            selectedArticleTitle: selectedArticleForMetrics?.title,
            selectedArticleURL: selectedArticleForMetrics?.url,
            errorMessage: String(describing: error)
        )
    }
    print("Error: \(error)")
    exit(1)
}

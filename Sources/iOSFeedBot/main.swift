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

let runStartedAt = Date()
var metricsStore: SQLiteMetricsStore?
var runID: Int64?
var articlesFound = 0
var selectedArticleForMetrics: Article?

do {
    // First validate config
    Config.validate()

    metricsStore = try? SQLiteMetricsStore(path: Config.metricsDatabasePath)
    runID = try? metricsStore?.startRun(startedAt: runStartedAt)
    
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
    
    print("Fetching blog directory...")
    let blogs = try await measure("directory_fetch", metricsStore: metricsStore, runID: runID) {
        try await directoryService.fetchBlogs()
    }
    
    print("Fetching recent articles from \(blogs.count) feeds...")
    let articles = try await measure("feed_fetch", metricsStore: metricsStore, runID: runID) {
        await feedService.fetchAllRecent(blogs: blogs)
    }
    articlesFound = articles.count
    print("Found \(articles.count) articles in the last 24h.")
    
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
    
    print("Selecting best article...")
    let selectedArticle = try await measure("article_selection", metricsStore: metricsStore, runID: runID) {
        try await aiService.selectArticle(from: articles)
    }
    selectedArticleForMetrics = selectedArticle

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

    if post.isEmpty {
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
    
    // Add UTM parameters to the URL
    let trackedURL = appendUTMParameters(to: selectedArticle.url)
    
    // Format the post with a hyperlinked title
    var lines = post.components(separatedBy: .newlines)
    if !lines.isEmpty {
        let title = lines[0]
        lines[0] = "<a href=\"\(trackedURL)\"><b>\(escapeHTML(title))</b></a>"
    }
    
    // Escape the rest of the post (except our already formatted title)
    for i in 1..<lines.count {
        lines[i] = escapeHTML(lines[i])
    }
    let formattedPost = lines.joined(separator: "\n")
    
    print("Fetching OG image...")
    let ogImageURL = try await measure("og_image_fetch", metricsStore: metricsStore, runID: runID) {
        await metadataService.fetchOGImageURL(for: selectedArticle.url)
    }
    
    if let ogImageURL = ogImageURL {
        print("Publishing to Telegram with image...")
        do {
            let messageID = try await measure("telegram_publish", metricsStore: metricsStore, runID: runID) {
                try await telegramService.sendPhoto(url: ogImageURL, caption: formattedPost)
            }
            if let metricsStore, let runID {
                try? metricsStore.recordTelegramPost(
                    runID: runID,
                    messageID: messageID,
                    method: "sendPhoto",
                    articleURL: selectedArticle.url,
                    title: selectedArticle.title,
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
                    method: "sendPhoto",
                    articleURL: selectedArticle.url,
                    title: selectedArticle.title,
                    status: "failure",
                    errorMessage: String(describing: error)
                )
            }
            throw error
        }
    } else {
        print("Publishing to Telegram (no image found)...")
        do {
            let messageID = try await measure("telegram_publish", metricsStore: metricsStore, runID: runID) {
                try await telegramService.sendMessage(formattedPost)
            }
            if let metricsStore, let runID {
                try? metricsStore.recordTelegramPost(
                    runID: runID,
                    messageID: messageID,
                    method: "sendMessage",
                    articleURL: selectedArticle.url,
                    title: selectedArticle.title,
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
                    method: "sendMessage",
                    articleURL: selectedArticle.url,
                    title: selectedArticle.title,
                    status: "failure",
                    errorMessage: String(describing: error)
                )
            }
            throw error
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

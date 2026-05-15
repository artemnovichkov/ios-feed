import Foundation

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

do {
    // First validate config
    Config.validate()
    
    let directoryService = DirectoryService()
    let feedService = FeedService()
    let aiService = AIService()
    let articleContentService = ArticleContentService()
    let metadataService = MetadataService()
    let telegramService = TelegramService()
    
    print("Fetching blog directory...")
    let blogs = try await directoryService.fetchBlogs()
    
    print("Fetching recent articles from \(blogs.count) feeds...")
    let articles = await feedService.fetchAllRecent(blogs: blogs)
    print("Found \(articles.count) articles in the last 24h.")
    
    if articles.isEmpty {
        print("No new articles found.")
        exit(0)
    }
    
    print("Selecting best article...")
    let selectedArticle = try await aiService.selectArticle(from: articles)

    print("Fetching selected article content...")
    let articleContent = await articleContentService.fetchContent(for: selectedArticle.url)
        ?? selectedArticle.description
        ?? ""

    print("Generating post from article content...")
    let post = try await aiService.generatePost(for: selectedArticle, content: articleContent)

    if post.isEmpty {
         print("AI failed to generate a post.")
         exit(0)
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
    let ogImageURL = await metadataService.fetchOGImageURL(for: selectedArticle.url)
    
    if let ogImageURL = ogImageURL {
        print("Publishing to Telegram with image...")
        try await telegramService.sendPhoto(url: ogImageURL, caption: formattedPost)
    } else {
        print("Publishing to Telegram (no image found)...")
        try await telegramService.sendMessage(formattedPost)
    }
    
    print("Done!")
} catch {
    print("Error: \(error)")
    exit(1)
}

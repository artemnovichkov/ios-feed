import Foundation

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

do {
    // First validate config
    Config.validate()
    
    let directoryService = DirectoryService()
    let feedService = FeedService()
    let aiService = AIService()
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
    
    print("Selecting best article and generating post...")
    let result = try await aiService.generatePost(articles: articles)
    
    if result.post.isEmpty {
         print("AI failed to generate a post.")
         exit(0)
    }
    
    // Format the post with a hyperlinked title
    var lines = result.post.components(separatedBy: .newlines)
    if !lines.isEmpty {
        let title = lines[0]
        lines[0] = "<a href=\"\(result.url)\"><b>\(escapeHTML(title))</b></a>"
    }
    
    // Escape the rest of the post (except our already formatted title)
    for i in 1..<lines.count {
        lines[i] = escapeHTML(lines[i])
    }
    let formattedPost = lines.joined(separator: "\n")
    
    print("Fetching OG image...")
    let ogImageURL = await metadataService.fetchOGImageURL(for: result.url)
    
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

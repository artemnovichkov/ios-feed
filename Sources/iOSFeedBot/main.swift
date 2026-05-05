import Foundation

do {
    // First validate config
    Config.validate()
    
    let directoryService = DirectoryService()
    let feedService = FeedService()
    let aiService = AIService()
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
    let post = try await aiService.generatePost(articles: articles)
    
    if post.isEmpty {
         print("AI failed to generate a post.")
         exit(0)
    }
    
    print("Publishing to Telegram...")
    try await telegramService.sendMessage(post)
    
    print("Done!")
} catch {
    print("Error: \(error)")
    exit(1)
}

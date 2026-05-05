# iOS Feed Bot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Swift CLI tool that fetches the latest iOS development articles from the iOS Dev Directory, uses OpenAI to select the best one from the last 24 hours, and posts it to a Telegram channel.

**Architecture:** A stateless Swift CLI tool executed via cron. It uses concurrent RSS fetching, OpenAI's GPT-4o-mini for selection/generation, and the Telegram Bot API for publishing.

**Tech Stack:** Swift (SPM), FeedKit (RSS parsing), OpenAI API, Telegram Bot API.

---

### Task 1: Project Initialization

**Files:**
- Create: `Package.swift`
- Create: `Sources/iOSFeedBot/main.swift`

- [ ] **Step 1: Create Package.swift with dependencies**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iOSFeedBot",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2")
    ],
    targets: [
        .executableTarget(
            name: "iOSFeedBot",
            dependencies: [
                .product(name: "FeedKit", package: "FeedKit")
            ]
        )
    ]
)
```

- [ ] **Step 2: Create a placeholder main.swift**

```swift
import Foundation

print("Hello, iOS Feed Bot!")
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: SUCCESS

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/iOSFeedBot/main.swift
git commit -m "chore: initialize swift executable project"
```

---

### Task 2: Data Models & Environment Config

**Files:**
- Create: `Sources/iOSFeedBot/Models.swift`
- Create: `Sources/iOSFeedBot/Config.swift`

- [ ] **Step 1: Define Blog and Article models**

```swift
import Foundation

struct Blog: Codable {
    let title: String
    let url: String
    let feed: String
}

struct Article {
    let title: String
    let url: String
    let description: String?
    let pubDate: Date
}

struct OpenAIRequest: Codable {
    let model: String = "gpt-4o-mini"
    let messages: [Message]
    
    struct Message: Codable {
        let role: String
        let content: String
    }
}
```

- [ ] **Step 2: Define Config to read environment variables**

```swift
import Foundation

struct Config {
    static let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    static let telegramBotToken = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] ?? ""
    static let telegramChannelId = ProcessInfo.processInfo.environment["TELEGRAM_CHANNEL_ID"] ?? ""
    static let directoryUrl = "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/main/blogs.json"
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/iOSFeedBot/Models.swift Sources/iOSFeedBot/Config.swift
git commit -m "feat: add models and config"
```

---

### Task 3: Fetching Blog Directory

**Files:**
- Create: `Sources/iOSFeedBot/DirectoryService.swift`

- [ ] **Step 1: Implement fetchBlogs**

```swift
import Foundation

class DirectoryService {
    func fetchBlogs() async throws -> [Blog] {
        guard let url = URL(string: Config.directoryUrl) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // The blogs.json structure is an array of categories, each having a 'blogs' array
        struct Category: Codable {
            let blogs: [Blog]
        }
        let categories = try JSONDecoder().decode([Category].self, from: data)
        return categories.flatMap { $0.blogs }
    }
}
```

- [ ] **Step 2: Add test or print verification in main.swift**

- [ ] **Step 3: Commit**

```bash
git add Sources/iOSFeedBot/DirectoryService.swift
git commit -m "feat: implement directory fetching"
```

---

### Task 4: RSS Feed Parsing

**Files:**
- Create: `Sources/iOSFeedBot/FeedService.swift`

- [ ] **Step 1: Implement fetchRecentArticles with concurrency**

```swift
import Foundation
import FeedKit

class FeedService {
    func fetchArticles(from blog: Blog) async -> [Article] {
        guard let url = URL(string: blog.feed) else { return [] }
        let parser = FeedParser(URL: url)
        
        return await withCheckedContinuation { continuation in
            parser.parseAsync { result in
                var articles: [Article] = []
                switch result {
                case .success(let feed):
                    switch feed {
                    case .rss(let rssFeed):
                        articles = rssFeed.items?.compactMap { item in
                            guard let pubDate = item.pubDate else { return nil }
                            return Article(title: item.title ?? "", url: item.link ?? "", description: item.description, pubDate: pubDate)
                        } ?? []
                    case .atom(let atomFeed):
                        articles = atomFeed.entries?.compactMap { entry in
                            guard let pubDate = entry.published ?? entry.updated else { return nil }
                            return Article(title: entry.title ?? "", url: entry.links?.first?.attributes?.href ?? "", description: entry.summary?.value, pubDate: pubDate)
                        } ?? []
                    default: break
                    }
                case .failure: break
                }
                continuation.resume(returning: articles)
            }
        }
    }
    
    func fetchAllRecent(blogs: [Blog]) async -> [Article] {
        let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
        
        return await withTaskGroup(of: [Article].self) { group in
            for blog in blogs {
                group.addTask {
                    await self.fetchArticles(from: blog)
                }
            }
            
            var all: [Article] = []
            for await articles in group {
                all.append(contentsOf: articles.filter { $0.pubDate > yesterday })
            }
            return all
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/iOSFeedBot/FeedService.swift
git commit -m "feat: implement RSS parsing with concurrency"
```

---

### Task 5: AI Selection & Post Generation

**Files:**
- Create: `Sources/iOSFeedBot/AIService.swift`

- [ ] **Step 1: Implement selectAndGeneratePost**

```swift
import Foundation

class AIService {
    func generatePost(articles: [Article]) async throws -> String {
        guard !articles.isEmpty else { return "" }
        
        let articleList = articles.map { "- \($0.title) (\($0.url))" }.joined(separator: "\n")
        let prompt = """
        I have a list of iOS development articles published in the last 24 hours:
        \(articleList)
        
        Please select the single most interesting and technically valuable article.
        Generate a Telegram post for it in the following format:
        
        [Title of the Article]
        
        [A short summary (2-3 sentences) explaining why it is interesting for iOS developers]
        
        #[Hashtag1] #[Hashtag2] #[SourceDomain]
        
        Return ONLY the post text.
        """
        
        let requestBody = OpenAIRequest(messages: [.init(role: "user", content: prompt)])
        let data = try JSONEncoder().encode(requestBody)
        
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.openaiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        
        let (responseData, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: responseData)
        return response.choices.first?.message.content ?? ""
    }
}

struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/iOSFeedBot/AIService.swift
git commit -m "feat: implement AI selection and generation"
```

---

### Task 6: Telegram Posting

**Files:**
- Create: `Sources/iOSFeedBot/TelegramService.swift`

- [ ] **Step 1: Implement sendMessage**

```swift
import Foundation

class TelegramService {
    func sendMessage(_ text: String) async throws {
        guard !text.isEmpty else { return }
        let urlString = "https://api.telegram.org/bot\(Config.telegramBotToken)/sendMessage"
        guard let url = URL(string: urlString) else { return }
        
        let payload: [String: Any] = [
            "chat_id": Config.telegramChannelId,
            "text": text,
            "parse_mode": "HTML"
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        // Check for success status code if needed
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/iOSFeedBot/TelegramService.swift
git commit -m "feat: implement Telegram publishing"
```

---

### Task 7: Final Integration

**Files:**
- Modify: `Sources/iOSFeedBot/main.swift`

- [ ] **Step 1: Implement the main execution flow**

```swift
import Foundation

@main
struct App {
    static func main() async {
        do {
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
                return
            }
            
            print("Selecting best article and generating post...")
            let post = try await aiService.generatePost(articles: articles)
            
            print("Publishing to Telegram...")
            try await telegramService.sendMessage(post)
            
            print("Done!")
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
}
```

- [ ] **Step 2: Final build verification**

Run: `swift build`
Expected: SUCCESS

- [ ] **Step 3: Commit**

```bash
git add Sources/iOSFeedBot/main.swift
git commit -m "feat: integrate all services and finalize app"
```

---

### Task 8: Deployment & Cron Setup

**Files:**
- Create: `README.md`

- [ ] **Step 1: Document environment variables and cron job**

```markdown
# iOS Feed Bot Deployment

## Environment Variables
- `OPENAI_API_KEY`: Your OpenAI API Key.
- `TELEGRAM_BOT_TOKEN`: Your Telegram Bot Token.
- `TELEGRAM_CHANNEL_ID`: Your Telegram Channel ID (e.g., @mychannel).

## Build
```bash
swift build -c release
```

## Run
```bash
export OPENAI_API_KEY=...
export TELEGRAM_BOT_TOKEN=...
export TELEGRAM_CHANNEL_ID=...
./.build/release/iOSFeedBot
```

## Cron Setup
To run daily at 9:00 AM:
```bash
0 9 * * * cd /path/to/ios-feed && export OPENAI_API_KEY=... && export TELEGRAM_BOT_TOKEN=... && export TELEGRAM_CHANNEL_ID=... && ./.build/release/iOSFeedBot >> log.txt 2>&1
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add deployment instructions"
```

import Foundation
import FeedKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct FeedService {
    func fetchArticles(from blog: Blog) async -> [Article] {
        guard let feedUrlString = blog.feedUrl, let url = URL(string: feedUrlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        request.setValue("iOSFeedBot/1.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let parser = FeedParser(data: data)
            
            return await withCheckedContinuation { continuation in
                parser.parseAsync { result in
                    var articles: [Article] = []
                    switch result {
                    case .success(let feed):
                        switch feed {
                        case .rss(let rssFeed):
                            articles = rssFeed.items?.compactMap { item in
                                guard let pubDate = item.pubDate else { return nil }
                                return Article(title: item.title ?? "", url: item.link ?? "", description: Self.stripHTML(item.description), pubDate: pubDate, author: Self.author(articleURL: item.link ?? "", blogAuthor: blog.author))
                            } ?? []
                        case .atom(let atomFeed):
                            articles = atomFeed.entries?.compactMap { entry in
                                guard let pubDate = entry.published ?? entry.updated else { return nil }
                                let link = entry.links?.first(where: { $0.attributes?.rel == "alternate" })?.attributes?.href ?? entry.links?.first?.attributes?.href ?? ""
                                return Article(title: entry.title ?? "", url: link, description: Self.stripHTML(entry.summary?.value), pubDate: pubDate, author: Self.author(articleURL: link, blogAuthor: blog.author))
                            } ?? []
                        default: break
                        }
                    case .failure(let error):
                        print("Failed to parse feed from \(feedUrlString): \(error)")
                    }
                    continuation.resume(returning: articles)
                }
            }
        } catch {
            print("Failed to fetch feed from \(feedUrlString): \(error)")
            return []
        }
    }

    /// Author shown under the post title. Official items get none ("by Apple" says nothing),
    /// and Swift Package Index items get the package owner instead of the index maintainers.
    static func author(articleURL: String, blogAuthor: String?) -> String? {
        if ArticleFilter.isOfficial(articleURL) { return nil }
        if ArticleFilter.sourceKey(articleURL).hasSuffix("swiftpackageindex.com") {
            let path = URLComponents(string: articleURL)?.path ?? ""
            guard let owner = path.split(separator: "/").first, owner != "blog" else { return blogAuthor }
            return String(owner)
        }
        return blogAuthor
    }

    private static func stripHTML(_ string: String?) -> String? {
        guard let string = string else { return nil }
        return string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func fetchAllRecent(blogs: [Blog], maxAge: TimeInterval = 24 * 60 * 60) async -> [Article] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        let maxConcurrentTasks = 15
        
        return await withTaskGroup(of: [Article].self) { group in
            var all: [Article] = []
            var index = 0
            
            // Initial tasks
            while index < blogs.count && index < maxConcurrentTasks {
                let blog = blogs[index]
                group.addTask {
                    await self.fetchArticles(from: blog)
                }
                index += 1
            }
            
            // As tasks finish, add new ones until all blogs are processed
            for await articles in group {
                all.append(contentsOf: articles.filter { $0.pubDate > cutoff })
                
                if index < blogs.count {
                    let blog = blogs[index]
                    group.addTask {
                        await self.fetchArticles(from: blog)
                    }
                    index += 1
                }
            }
            return all
        }
    }
}

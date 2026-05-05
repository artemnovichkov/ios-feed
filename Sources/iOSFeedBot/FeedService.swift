import Foundation
import FeedKit

class FeedService {
    func fetchArticles(from blog: Blog) async -> [Article] {
        guard let feedUrlString = blog.feedUrl, let url = URL(string: feedUrlString) else { return [] }
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

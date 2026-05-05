import Foundation
import FeedKit

class FeedService {
    func fetchArticles(from blog: Blog) async -> [Article] {
        guard let feedUrlString = blog.feedUrl, let url = URL(string: feedUrlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        
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
                                return Article(title: item.title ?? "", url: item.link ?? "", description: item.description, pubDate: pubDate)
                            } ?? []
                        case .atom(let atomFeed):
                            articles = atomFeed.entries?.compactMap { entry in
                                guard let pubDate = entry.published ?? entry.updated else { return nil }
                                let link = entry.links?.first(where: { $0.attributes?.rel == "alternate" })?.attributes?.href ?? entry.links?.first?.attributes?.href ?? ""
                                return Article(title: entry.title ?? "", url: link, description: entry.summary?.value, pubDate: pubDate)
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
    
    func fetchAllRecent(blogs: [Blog]) async -> [Article] {
        let yesterday = Date().addingTimeInterval(-24 * 60 * 60)
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
                all.append(contentsOf: articles.filter { $0.pubDate > yesterday })
                
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

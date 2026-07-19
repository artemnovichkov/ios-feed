import Foundation

enum CandidateTier {
    case fresh
    case backfill
    case repost
}

enum ArticleFilter {
    /// Picks the candidate pool for selection, relaxing constraints step by step
    /// so that a daily post is possible whenever any content exists:
    /// 1. fresh articles never posted before;
    /// 2. older articles (within the extended fetch window) never posted before;
    /// 3. anything not posted recently (reposts of old items as a last resort).
    static func candidates(
        freshArticles: [Article],
        allArticles: [Article],
        postedURLs: Set<String>,
        recentlyPostedURLs: Set<String>
    ) -> (articles: [Article], tier: CandidateTier) {
        let fresh = uniqueArticles(freshArticles, excludingPostedURLs: postedURLs)
        if !fresh.isEmpty {
            return (fresh, .fresh)
        }
        let backfill = uniqueArticles(allArticles, excludingPostedURLs: postedURLs)
        if !backfill.isEmpty {
            return (backfill, .backfill)
        }
        return (uniqueArticles(allArticles, excludingPostedURLs: recentlyPostedURLs), .repost)
    }

    /// Normalizes a URL to a stable key for deduplication:
    /// lowercased host without "www.", no scheme, no query/fragment, no trailing slash.
    /// Swift Package Index URLs are truncated to owner/repo so every release
    /// of the same package maps to the same key.
    static func normalizeURL(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return urlString.lowercased()
        }

        var host = components.host?.lowercased() ?? ""
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }

        var path = components.path.lowercased()
        if host.hasSuffix("swiftpackageindex.com") {
            let ownerAndRepo = path.split(separator: "/").prefix(2)
            path = "/" + ownerAndRepo.joined(separator: "/")
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }

        return host + path
    }

    /// Drops articles that were already posted and collapses in-batch duplicates
    /// (e.g. several releases of the same package in one day), keeping the newest item.
    static func uniqueArticles(_ articles: [Article], excludingPostedURLs postedURLs: Set<String>) -> [Article] {
        var seen = Set<String>()
        var result: [Article] = []
        for article in articles.sorted(by: { $0.pubDate > $1.pubDate }) {
            let key = normalizeURL(article.url)
            guard !postedURLs.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(article)
        }
        return result
    }
}

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
        let fresh = technicalCandidates(uniqueArticles(freshArticles, excludingPostedURLs: postedURLs))
        if !fresh.isEmpty {
            return (fresh, .fresh)
        }
        let backfill = technicalCandidates(uniqueArticles(allArticles, excludingPostedURLs: postedURLs))
        if !backfill.isEmpty {
            return (backfill, .backfill)
        }
        return (
            technicalCandidates(uniqueArticles(allArticles, excludingPostedURLs: recentlyPostedURLs)),
            .repost
        )
    }

    /// Drops marketing/business items from a candidate pool, but never empties it:
    /// if nothing technical is left, the original pool is kept so a daily post is still possible.
    static func technicalCandidates(_ articles: [Article]) -> [Article] {
        let technical = articles.filter { !isMarketingContent(title: $0.title, description: $0.description) }
        return technical.isEmpty ? articles : technical
    }

    /// True for growth/monetization/business content that mentions no technical subject.
    /// A technical keyword anywhere cancels the match, so posts like
    /// "Building a paywall with StoreKit 2" stay in the pool.
    static func isMarketingContent(title: String, description: String?) -> Bool {
        let text = [title, description ?? ""].joined(separator: " ")
        let tokens = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let normalized = " " + tokens.joined(separator: " ") + " "
        let tokenSet = Set(tokens)

        func matches(_ keywords: [String]) -> Bool {
            keywords.contains { keyword in
                keyword.contains(" ") ? normalized.contains(" \(keyword) ") : tokenSet.contains(keyword)
            }
        }

        return matches(marketingKeywords) && !matches(technicalKeywords)
    }

    private static let marketingKeywords = [
        "marketing", "marketer", "aso", "app store optimization", "user acquisition",
        "growth", "monetization", "monetize", "monetizing", "revenue", "mrr", "ltv",
        "roas", "cpi", "ctr", "paywall", "paywalls", "pricing", "affiliate", "affiliates",
        "commission", "commissions", "payout", "payouts", "ads", "advertising",
        "advertisement", "advertisements", "campaign", "campaigns", "conversion",
        "conversions", "churn", "funnel", "seo", "sponsorship", "sponsor", "branding",
        "solopreneur", "indie hacker", "founder", "founders", "sales", "promo",
        "promotion", "promoting", "product hunt", "influencer", "impressions",
        "subscribers", "profit", "pitch"
    ]

    private static let technicalKeywords = [
        "swift", "swiftui", "uikit", "appkit", "xcode", "storekit", "swiftdata",
        "coredata", "combine", "metal", "arkit", "widgetkit", "api", "apis", "sdk",
        "concurrency", "actor", "actors", "async", "await", "sendable", "protocol",
        "generics", "compiler", "runtime", "memory", "crash", "crashes", "debug",
        "debugging", "performance", "benchmark", "profiling", "instruments",
        "algorithm", "cache", "caching", "networking", "urlsession", "macro", "macros",
        "package", "spm", "swiftpm", "testing", "xctest", "animation", "layout",
        "accessibility", "keychain", "encryption", "threading", "observable",
        "architecture", "refactoring", "linker", "binary", "code", "implementation",
        "extension", "extensions", "framework", "frameworks", "wwdc"
    ]

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

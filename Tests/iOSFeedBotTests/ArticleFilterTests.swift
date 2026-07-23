import XCTest
@testable import iOSFeedBot

final class ArticleFilterTests: XCTestCase {
    func testNormalizeURLStripsSchemeWWWQueryAndTrailingSlash() {
        XCTAssertEqual(
            ArticleFilter.normalizeURL("https://www.Example.com/Post/?utm_source=telegram#section"),
            "example.com/post"
        )
        XCTAssertEqual(
            ArticleFilter.normalizeURL("http://example.com/post"),
            "example.com/post"
        )
    }

    func testNormalizeURLCollapsesSwiftPackageIndexReleases() {
        let base = ArticleFilter.normalizeURL("https://swiftpackageindex.com/owner/SomePackage")
        XCTAssertEqual(base, "swiftpackageindex.com/owner/somepackage")
        XCTAssertEqual(
            ArticleFilter.normalizeURL("https://swiftpackageindex.com/owner/SomePackage/5.8.9"),
            base
        )
        XCTAssertEqual(
            ArticleFilter.normalizeURL("https://swiftpackageindex.com/owner/SomePackage/releases"),
            base
        )
    }

    func testUniqueArticlesExcludesAlreadyPostedURLs() {
        let articles = [
            Article(title: "New Post", url: "https://example.com/new", description: nil, pubDate: Date()),
            Article(title: "Old Post", url: "https://example.com/old/", description: nil, pubDate: Date())
        ]
        let posted: Set<String> = [ArticleFilter.normalizeURL("https://www.example.com/old")]

        let result = ArticleFilter.uniqueArticles(articles, excludingPostedURLs: posted)

        XCTAssertEqual(result.map(\.title), ["New Post"])
    }

    func testCandidatesFallBackFromFreshToBackfillToRepost() {
        let freshPosted = Article(
            title: "Fresh but posted",
            url: "https://example.com/posted-fresh",
            description: nil,
            pubDate: Date()
        )
        let olderUnposted = Article(
            title: "Older unposted",
            url: "https://example.com/older",
            description: nil,
            pubDate: Date(timeIntervalSinceNow: -48 * 60 * 60)
        )
        let postedFreshURL = ArticleFilter.normalizeURL(freshPosted.url)
        let olderURL = ArticleFilter.normalizeURL(olderUnposted.url)

        // Tier 1: fresh unposted article wins.
        let fresh = ArticleFilter.candidates(
            freshArticles: [freshPosted, olderUnposted],
            allArticles: [freshPosted, olderUnposted],
            postedURLs: [],
            recentlyPostedURLs: []
        )
        XCTAssertEqual(fresh.tier, .fresh)
        XCTAssertEqual(fresh.articles.count, 2)

        // Tier 2: everything fresh already posted — older window kicks in.
        let backfill = ArticleFilter.candidates(
            freshArticles: [freshPosted],
            allArticles: [freshPosted, olderUnposted],
            postedURLs: [postedFreshURL],
            recentlyPostedURLs: [postedFreshURL]
        )
        XCTAssertEqual(backfill.tier, .backfill)
        XCTAssertEqual(backfill.articles.map(\.title), ["Older unposted"])

        // Tier 3: everything was posted at some point — allow non-recent reposts.
        let repost = ArticleFilter.candidates(
            freshArticles: [freshPosted],
            allArticles: [freshPosted, olderUnposted],
            postedURLs: [postedFreshURL, olderURL],
            recentlyPostedURLs: [postedFreshURL]
        )
        XCTAssertEqual(repost.tier, .repost)
        XCTAssertEqual(repost.articles.map(\.title), ["Older unposted"])
    }

    func testMarketingContentDetection() {
        XCTAssertTrue(
            ArticleFilter.isMarketingContent(
                title: "Make Ugly Ads to Grow Your App",
                description: "Why ugly ads capture more attention than polished ones."
            )
        )
        XCTAssertTrue(
            ArticleFilter.isMarketingContent(
                title: "How Reduced App Store Commissions Change Your Affiliate Payout Math",
                description: nil
            )
        )
        // Technical keywords cancel the marketing signal.
        XCTAssertFalse(
            ArticleFilter.isMarketingContent(
                title: "Building a paywall with StoreKit 2",
                description: "Implementing subscription pricing with the SubscriptionStoreView API."
            )
        )
        XCTAssertFalse(
            ArticleFilter.isMarketingContent(
                title: "Understanding actor reentrancy in Swift",
                description: nil
            )
        )
    }

    func testCandidatesDropMarketingItemsWhenTechnicalOnesExist() {
        let marketing = Article(
            title: "Grow Your App Revenue With Better Ads",
            url: "https://example.com/ads",
            description: nil,
            pubDate: Date()
        )
        let technical = Article(
            title: "Swift 6 concurrency migration notes",
            url: "https://example.com/swift6",
            description: nil,
            pubDate: Date(timeIntervalSinceNow: -3600)
        )

        let mixed = ArticleFilter.candidates(
            freshArticles: [marketing, technical],
            allArticles: [marketing, technical],
            postedURLs: [],
            recentlyPostedURLs: []
        )
        XCTAssertEqual(mixed.articles.map(\.title), ["Swift 6 concurrency migration notes"])

        // Marketing-only pool is kept so a daily post is still possible.
        let marketingOnly = ArticleFilter.candidates(
            freshArticles: [marketing],
            allArticles: [marketing],
            postedURLs: [],
            recentlyPostedURLs: []
        )
        XCTAssertEqual(marketingOnly.tier, .fresh)
        XCTAssertEqual(marketingOnly.articles.map(\.title), [marketing.title])
    }

    func testUniqueArticlesCollapsesInBatchDuplicatesKeepingNewest() {
        let articles = [
            Article(
                title: "SomePackage - 4.11.0",
                url: "https://swiftpackageindex.com/owner/SomePackage",
                description: nil,
                pubDate: Date(timeIntervalSinceNow: -3600)
            ),
            Article(
                title: "SomePackage - 5.8.9",
                url: "https://swiftpackageindex.com/owner/SomePackage",
                description: nil,
                pubDate: Date()
            )
        ]

        let result = ArticleFilter.uniqueArticles(articles, excludingPostedURLs: [])

        XCTAssertEqual(result.map(\.title), ["SomePackage - 5.8.9"])
    }
}

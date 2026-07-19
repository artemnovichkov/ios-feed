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

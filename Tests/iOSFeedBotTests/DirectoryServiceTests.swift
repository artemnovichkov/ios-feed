import XCTest
@testable import iOSFeedBot

final class DirectoryServiceTests: XCTestCase {
    func testParseBlogsSkipsMarketingCategoryNonEnglishAndFeedlessSources() throws {
        let json = """
        [
          {
            "language": "en",
            "title": "English Language",
            "categories": [
              {
                "title": "Development Blogs",
                "slug": "development",
                "sites": [
                  {
                    "title": "English Blog",
                    "site_url": "https://example.com",
                    "feed_url": "https://example.com/feed.xml"
                  },
                  {
                    "title": "English Blog Without Feed",
                    "site_url": "https://no-feed.example.com"
                  }
                ]
              },
              {
                "title": "Marketing and Business Blogs",
                "slug": "marketing",
                "sites": [
                  {
                    "title": "Marketing Blog",
                    "site_url": "https://marketing.example.com",
                    "feed_url": "https://marketing.example.com/feed.xml"
                  }
                ]
              }
            ]
          },
          {
            "language": "ko",
            "title": "Korean Language",
            "categories": [
              {
                "title": "Development Blogs",
                "sites": [
                  {
                    "title": "Korean Blog",
                    "site_url": "https://green1229.tistory.com/",
                    "feed_url": "https://green1229.tistory.com/rss"
                  }
                ]
              }
            ]
          }
        ]
        """

        let blogs = try DirectoryService.parseBlogs(from: Data(json.utf8))

        XCTAssertEqual(blogs.count, 1)
        XCTAssertEqual(blogs.first?.title, "English Blog")
        XCTAssertEqual(blogs.first?.siteUrl, "https://example.com")
        XCTAssertEqual(blogs.first?.feedUrl, "https://example.com/feed.xml")
    }

    func testParseBlogsSkipsExcludedFeedsAndMergeAddsOnlyNewFeeds() throws {
        let json = """
        [
          {
            "language": "en",
            "categories": [
              {
                "slug": "updates",
                "sites": [
                  { "title": "Apple News", "site_url": "https://developer.apple.com/news/", "feed_url": "https://developer.apple.com/news/rss/news.rss" },
                  { "title": "Commits", "site_url": "https://example.com", "feed_url": "https://example.com/commits.atom" }
                ]
              }
            ]
          }
        ]
        """

        let blogs = try DirectoryService.parseBlogs(
            from: Data(json.utf8),
            excludingFeedUrls: ["https://example.com/commits.atom"]
        )
        XCTAssertEqual(blogs.map(\.title), ["Apple News"])

        let merged = DirectoryService.merge(blogs, with: [
            Blog(title: "Duplicate", siteUrl: "https://developer.apple.com/news/", feedUrl: "https://developer.apple.com/news/rss/news.rss"),
            Blog(title: "Forum", siteUrl: "https://forums.swift.org", feedUrl: "https://forums.swift.org/c/evolution/announce/12.rss")
        ])
        XCTAssertEqual(merged.map(\.title), ["Apple News", "Forum"])
    }
}

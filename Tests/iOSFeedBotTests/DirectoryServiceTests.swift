import XCTest
@testable import iOSFeedBot

final class DirectoryServiceTests: XCTestCase {
    func testParseBlogsReturnsOnlyEnglishSourcesWithFeedURLs() throws {
        let json = """
        [
          {
            "language": "en",
            "title": "English Language",
            "categories": [
              {
                "title": "Development Blogs",
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
}

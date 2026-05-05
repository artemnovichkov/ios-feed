import Foundation

struct Blog: Codable {
    let title: String
    let siteUrl: String
    let feedUrl: String?

    enum CodingKeys: String, CodingKey {
        case title
        case siteUrl = "site_url"
        case feedUrl = "feed_url"
    }
}

struct Article {
    let title: String
    let url: String
    let description: String?
    let pubDate: Date
}

struct OpenAIRequest: Codable {
    var model: String = Config.openaiModel
    let messages: [Message]
    
    struct Message: Codable {
        let role: String
        let content: String
    }
}

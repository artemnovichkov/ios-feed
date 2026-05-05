import Foundation

struct Blog: Codable {
    let title: String
    let url: String
    let feed: String
}

struct Article {
    let title: String
    let url: String
    let description: String?
    let pubDate: Date
}

struct OpenAIRequest: Codable {
    let model: String = "gpt-4o-mini"
    let messages: [Message]
    
    struct Message: Codable {
        let role: String
        let content: String
    }
}

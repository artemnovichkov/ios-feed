import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AIError: Error {
    case invalidResponse(Int)
    case emptyResponse
    case invalidSelection
}

class AIService {
    private static let maxArticleContentCharacters = 12_000

    func selectArticle(from articles: [Article]) async throws -> Article {
        guard !articles.isEmpty else { throw AIError.emptyResponse }

        let prompt = Self.buildSelectionPrompt(articles: articles)
        let content = try await sendPrompt(prompt)

        guard let selectedID = Self.parseSelectedArticleID(from: content),
              articles.indices.contains(selectedID - 1) else {
            throw AIError.invalidSelection
        }

        return articles[selectedID - 1]
    }

    func generatePost(for article: Article, content: String) async throws -> String {
        let prompt = Self.buildPostPrompt(article: article, content: content)
        let response = try await sendPrompt(prompt)
        return try Self.parsePost(from: response)
    }

    func generatePost(articles: [Article]) async throws -> (url: String, post: String) {
        guard !articles.isEmpty else { return ("", "") }

        let article = try await selectArticle(from: articles)
        let post = try await generatePost(for: article, content: article.description ?? "")
        return (article.url, post)
    }

    static func buildSelectionPrompt(articles: [Article]) -> String {
        let articleList = articles.enumerated().map { index, article in
            var text = "\(index + 1). \(article.title) (\(article.url))"
            if let description = article.description, !description.isEmpty {
                text += "\n   Feed description: \(description)"
            }
            return text
        }.joined(separator: "\n")

        return """
        I have a list of iOS development articles published in the last 24 hours:
        \(articleList)

        Please select the single most interesting and technically valuable article.
        Select only an article written in English.

        Your response MUST follow this exact format:
        ID: [The number of the selected article]

        Instructions:
        - Return ONLY the ID line as specified above.
        - Do not use markdown code blocks or additional chatter.
        """
    }

    static func buildPostPrompt(article: Article, content: String) -> String {
        let articleContent = String(
            content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maxArticleContentCharacters)
        )

        return """
        Generate a Telegram post for this iOS development article.

        Title: \(article.title)
        URL: \(article.url)

        Article content:
        \(articleContent)

        Your response MUST follow this exact format:
        POST:
        [Title of the Article]

        [A short summary (2-3 sentences) based on the article content, explaining why it is interesting for iOS developers]

        #[Hashtag1] #[Hashtag2] #[SourceDomain]

        Instructions:
        - Return ONLY the post text as specified above.
        - Do not use markdown code blocks or additional chatter.
        - Ensure hashtags are valid (alphanumeric, no dots/spaces/special characters).
        - Sanitize the SourceDomain hashtag (e.g., "iosdev.com" -> "#iosdev").
        """
    }

    static func parseSelectedArticleID(from content: String) -> Int? {
        let pattern = #"(?i)\bID:\s*(\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }

        return Int(content[range])
    }

    static func parsePost(from content: String) throws -> String {
        let lines = content.components(separatedBy: .newlines)
        guard let postIndex = lines.firstIndex(where: { $0.hasPrefix("POST:") }) else {
            throw AIError.emptyResponse
        }

        let post = lines[(postIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !post.isEmpty else { throw AIError.emptyResponse }

        return post
    }

    private func sendPrompt(_ prompt: String) async throws -> String {
        let requestBody = OpenAIRequest(messages: [.init(role: "user", content: prompt)])
        let data = try JSONEncoder().encode(requestBody)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.openaiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOSFeedBot/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = data
        
        let (responseData, urlResponse) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AIError.invalidResponse(0)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AIError.invalidResponse(httpResponse.statusCode)
        }
        
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: responseData)
        guard let content = response.choices.first?.message.content else {
            throw AIError.emptyResponse
        }

        return content
    }
}

struct OpenAIResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}

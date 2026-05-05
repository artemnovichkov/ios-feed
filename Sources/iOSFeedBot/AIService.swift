import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AIError: Error {
    case invalidResponse(Int)
    case emptyResponse
}

class AIService {
    func generatePost(articles: [Article]) async throws -> (url: String, post: String) {
        guard !articles.isEmpty else { return ("", "") }
        
        let articleList = articles.map { article in
            var text = "- \(article.title) (\(article.url))"
            if let description = article.description, !description.isEmpty {
                text += "\n  Description: \(description)"
            }
            return text
        }.joined(separator: "\n")
        
        let prompt = """
        I have a list of iOS development articles published in the last 24 hours:
        \(articleList)
        
        Please select the single most interesting and technically valuable article.
        Generate a Telegram post for it.
        
        Your response MUST follow this exact format:
        URL: [The full URL of the selected article]
        POST:
        [Title of the Article]
        
        [A short summary (2-3 sentences) explaining why it is interesting for iOS developers]
        
        #[Hashtag1] #[Hashtag2] #[SourceDomain]
        
        Instructions:
        - Return ONLY the URL and the post text as specified above.
        - Do not use markdown code blocks or additional chatter.
        - Ensure hashtags are valid (alphanumeric, no dots/spaces/special characters).
        - Sanitize the SourceDomain hashtag (e.g., "iosdev.com" -> "#iosdev").
        """
        
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
        
        // Parse the URL and POST content
        let lines = content.components(separatedBy: .newlines)
        guard let urlLine = lines.first(where: { $0.hasPrefix("URL:") }),
              let postIndex = lines.firstIndex(where: { $0.hasPrefix("POST:") }) else {
            throw AIError.emptyResponse
        }
        
        let url = urlLine.replacingOccurrences(of: "URL:", with: "").trimmingCharacters(in: .whitespaces)
        let post = lines[(postIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (url, post)
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

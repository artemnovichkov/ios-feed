import Foundation

class AIService {
    func generatePost(articles: [Article]) async throws -> String {
        guard !articles.isEmpty else { return "" }
        
        let articleList = articles.map { "- \($0.title) (\($0.url))" }.joined(separator: "\n")
        let prompt = """
        I have a list of iOS development articles published in the last 24 hours:
        \(articleList)
        
        Please select the single most interesting and technically valuable article.
        Generate a Telegram post for it in the following format:
        
        [Title of the Article]
        
        [A short summary (2-3 sentences) explaining why it is interesting for iOS developers]
        
        #[Hashtag1] #[Hashtag2] #[SourceDomain]
        
        Return ONLY the post text.
        """
        
        let requestBody = OpenAIRequest(messages: [.init(role: "user", content: prompt)])
        let data = try JSONEncoder().encode(requestBody)
        
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.openaiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        
        let (responseData, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(OpenAIResponse.self, from: responseData)
        return response.choices.first?.message.content ?? ""
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

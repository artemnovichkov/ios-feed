import Foundation

class TelegramService {
    func sendMessage(_ text: String) async throws {
        guard !text.isEmpty else { return }
        let urlString = "https://api.telegram.org/bot\(Config.telegramBotToken)/sendMessage"
        guard let url = URL(string: urlString) else { return }
        
        let payload: [String: Any] = [
            "chat_id": Config.telegramChannelId,
            "text": text,
            "parse_mode": "HTML"
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, _) = try await URLSession.shared.data(for: request)
        // Check for success status code if needed
    }
}

import Foundation

enum TelegramError: Error {
    case invalidResponse(Int)
}

class TelegramService {
    func sendMessage(_ text: String) async throws {
        guard !text.isEmpty else { return }
        let urlString = "https://api.telegram.org/bot\(Config.telegramBotToken)/sendMessage"
        guard let url = URL(string: urlString) else { return }
        
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let payload: [String: Any] = [
            "chat_id": Config.telegramChannelId,
            "text": escapedText,
            "parse_mode": "HTML"
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iOSFeedBot/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelegramError.invalidResponse(0)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            print("Telegram API error: \(httpResponse.statusCode)")
            if let errorBody = String(data: data, encoding: .utf8) {
                print("Error body: \(errorBody)")
            }
            throw TelegramError.invalidResponse(httpResponse.statusCode)
        }
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TelegramError: Error {
    case invalidResponse(Int)
}

class TelegramService {
    func sendMessage(_ text: String) async throws {
        try await performAction(method: "sendMessage", payload: [
            "chat_id": Config.telegramChannelId,
            "text": text,
            "parse_mode": "HTML"
        ])
    }

    func sendPhoto(url: String, caption: String) async throws {
        try await performAction(method: "sendPhoto", payload: [
            "chat_id": Config.telegramChannelId,
            "photo": url,
            "caption": caption,
            "parse_mode": "HTML"
        ])
    }

    private func performAction(method: String, payload: [String: Any]) async throws {
        let urlString = "https://api.telegram.org/bot\(Config.telegramBotToken)/\(method)"
        guard let url = URL(string: urlString) else { return }
        
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

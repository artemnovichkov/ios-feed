import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TelegramError: Error {
    case invalidResponse(Int)
}

final class TelegramService: Sendable {
    func sendMessage(_ text: String) async throws -> Int? {
        try await performAction(method: "sendMessage", payload: [
            "chat_id": Config.telegramChannelId,
            "text": text,
            "parse_mode": "HTML"
        ])
    }

    func sendPhoto(url: String, caption: String) async throws -> Int? {
        try await performAction(method: "sendPhoto", payload: [
            "chat_id": Config.telegramChannelId,
            "photo": url,
            "caption": caption,
            "parse_mode": "HTML"
        ])
    }

    func getChatMemberCount() async throws -> Int {
        let response: TelegramAPIResponse<Int> = try await performAction(method: "getChatMemberCount", payload: [
            "chat_id": Config.telegramChannelId
        ])
        return response.result
    }

    private func performAction(method: String, payload: [String: Any]) async throws -> Int? {
        let response: TelegramAPIResponse<TelegramMessage> = try await performAction(method: method, payload: payload)
        return response.result.messageID
    }

    private func performAction<Response: Decodable>(method: String, payload: [String: Any]) async throws -> TelegramAPIResponse<Response> {
        let urlString = "https://api.telegram.org/bot\(Config.telegramBotToken)/\(method)"
        guard let url = URL(string: urlString) else { throw TelegramError.invalidResponse(0) }
        
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

        return try JSONDecoder().decode(TelegramAPIResponse<Response>.self, from: data)
    }
}

struct TelegramAPIResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
}

struct TelegramMessage: Decodable {
    let messageID: Int

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

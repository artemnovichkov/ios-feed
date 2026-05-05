import Foundation

struct Config {
    static let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    static let telegramBotToken = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] ?? ""
    static let telegramChannelId = ProcessInfo.processInfo.environment["TELEGRAM_CHANNEL_ID"] ?? ""
    static let directoryUrl = "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/main/blogs.json"
}

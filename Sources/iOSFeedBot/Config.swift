import Foundation

enum Config {
    static let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    static let openaiModel = "gpt-4o-mini"
    static let telegramBotToken = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] ?? ""
    static let telegramChannelId = ProcessInfo.processInfo.environment["TELEGRAM_CHANNEL_ID"] ?? ""
    static let directoryUrl = "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/main/blogs.json"

    static func validate() {
        let missingConfigs = [
            ("OPENAI_API_KEY", openaiKey),
            ("TELEGRAM_BOT_TOKEN", telegramBotToken),
            ("TELEGRAM_CHANNEL_ID", telegramChannelId)
        ].filter { $0.1.isEmpty }.map { $0.0 }

        if !missingConfigs.isEmpty {
            let message = "Error: Missing configuration environment variables: \(missingConfigs.joined(separator: ", "))"
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(1)
        }
    }
}

import Foundation

enum Config {
    static let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    static let openaiModel = ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-5-mini"
    static let telegramBotToken = ProcessInfo.processInfo.environment["TELEGRAM_BOT_TOKEN"] ?? ""
    static let telegramChannelId = ProcessInfo.processInfo.environment["TELEGRAM_CHANNEL_ID"] ?? ""
    static let directoryUrl = "https://raw.githubusercontent.com/daveverwer/iOSDevDirectory/main/blogs.json"
    /// Official sources missing from the directory.
    static let additionalBlogs = [
        Blog(
            title: "Swift Forums: Proposal Reviews",
            siteUrl: "https://forums.swift.org/c/evolution/proposal-reviews/21",
            feedUrl: "https://forums.swift.org/c/evolution/proposal-reviews/21.rss"
        ),
        Blog(
            title: "Swift Forums: Evolution Announcements",
            siteUrl: "https://forums.swift.org/c/evolution/announce/12",
            feedUrl: "https://forums.swift.org/c/evolution/announce/12.rss"
        )
    ]
    /// Directory feeds too noisy to post from. The swift-evolution commit log is replaced
    /// by the forum review/announcement feeds above.
    static let excludedFeedUrls: Set<String> = [
        "https://github.com/swiftlang/swift-evolution/commits/main.atom"
    ]
    static let metricsDatabasePath = ProcessInfo.processInfo.environment["METRICS_DB_PATH"] ?? ".build/metrics.sqlite"
    static let openAIInputPricePerMillionTokens = Double(ProcessInfo.processInfo.environment["OPENAI_INPUT_PRICE_PER_1M_TOKENS"] ?? "") ?? 0
    static let openAIOutputPricePerMillionTokens = Double(ProcessInfo.processInfo.environment["OPENAI_OUTPUT_PRICE_PER_1M_TOKENS"] ?? "") ?? 0

    /// Dry runs never touch Telegram, so they only need the OpenAI key.
    static func validate(requireTelegram: Bool = true) {
        var configs = [("OPENAI_API_KEY", openaiKey)]
        if requireTelegram {
            configs += [("TELEGRAM_BOT_TOKEN", telegramBotToken), ("TELEGRAM_CHANNEL_ID", telegramChannelId)]
        }
        let missingConfigs = configs.filter { $0.1.isEmpty }.map { $0.0 }

        if !missingConfigs.isEmpty {
            let message = "Error: Missing configuration environment variables: \(missingConfigs.joined(separator: ", "))"
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(1)
        }
    }
}

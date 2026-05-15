import Foundation

public struct OpenAIUsage: Codable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct OpenAIPricing: Sendable {
    public let inputPricePerMillionTokens: Double
    public let outputPricePerMillionTokens: Double

    public init(inputPricePerMillionTokens: Double, outputPricePerMillionTokens: Double) {
        self.inputPricePerMillionTokens = inputPricePerMillionTokens
        self.outputPricePerMillionTokens = outputPricePerMillionTokens
    }

    public func estimateCost(usage: OpenAIUsage) -> Double {
        let inputCost = Double(usage.promptTokens) / 1_000_000 * inputPricePerMillionTokens
        let outputCost = Double(usage.completionTokens) / 1_000_000 * outputPricePerMillionTokens
        return inputCost + outputCost
    }
}

public struct RunRecord: Codable, Sendable {
    public let id: Int64
    public let startedAt: Date
    public let endedAt: Date?
    public let status: String
    public let durationMilliseconds: Int?
    public let articlesFound: Int
    public let selectedArticleTitle: String?
    public let selectedArticleURL: String?
    public let errorMessage: String?
}

public struct StepRecord: Codable, Sendable {
    public let name: String
    public let durationMilliseconds: Int
    public let status: String
    public let errorMessage: String?
}

public struct AICallRecord: Codable, Sendable {
    public let operation: String
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
    public let durationMilliseconds: Int
    public let status: String
    public let estimatedCostUSD: Double
    public let errorMessage: String?
    public let createdAt: Date
}

public struct TelegramPostRecord: Codable, Sendable {
    public let messageID: Int?
    public let method: String
    public let articleURL: String?
    public let title: String?
    public let postedAt: Date
    public let status: String
    public let errorMessage: String?
}

public struct EngagementRecord: Codable, Sendable {
    public let messageID: Int
    public let capturedAt: Date
    public let subscriberCount: Int?
    public let reactionCount: Int?
    public let detailsJSON: String?
}

public struct DashboardSummary: Codable, Sendable {
    public let generatedAt: Date
    public let lastRun: RunRecord?
    public let successfulRuns: Int
    public let failedRuns: Int
    public let totalTokens: Int
    public let totalCostUSD: Double
    public let latestPost: TelegramPostRecord?
    public let latestEngagement: EngagementRecord?
}

public struct CostPoint: Codable, Sendable {
    public let day: String
    public let totalTokens: Int
    public let estimatedCostUSD: Double
}

public struct PerformancePoint: Codable, Sendable {
    public let stepName: String
    public let averageDurationMilliseconds: Int
    public let maxDurationMilliseconds: Int
}

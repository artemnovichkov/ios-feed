import XCTest
@testable import iOSFeedMetrics

final class MetricsStoreTests: XCTestCase {
    func testPricingEstimatesInputAndOutputTokenCost() {
        let pricing = OpenAIPricing(inputPricePerMillionTokens: 0.15, outputPricePerMillionTokens: 0.60)
        let usage = OpenAIUsage(promptTokens: 1_000_000, completionTokens: 500_000, totalTokens: 1_500_000)

        XCTAssertEqual(pricing.estimateCost(usage: usage), 0.45, accuracy: 0.0001)
    }

    func testStorePersistsRunAICallTelegramPostAndEngagement() throws {
        let store = try SQLiteMetricsStore(path: temporaryDatabasePath())
        let runID = try store.startRun(startedAt: Date(timeIntervalSince1970: 1_000))

        try store.recordAICall(
            runID: runID,
            operation: "post_generation",
            model: "gpt-4o-mini",
            usage: OpenAIUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150),
            durationMilliseconds: 321,
            status: "success",
            estimatedCostUSD: 0.000045,
            createdAt: Date(timeIntervalSince1970: 1_010)
        )
        try store.recordStep(runID: runID, name: "telegram_publish", durationMilliseconds: 250, status: "success")
        try store.recordTelegramPost(
            runID: runID,
            messageID: 42,
            method: "sendMessage",
            articleURL: "https://example.com/article",
            title: "Article",
            postedAt: Date(timeIntervalSince1970: 1_020),
            status: "success"
        )
        try store.recordEngagement(
            messageID: 42,
            capturedAt: Date(timeIntervalSince1970: 1_030),
            subscriberCount: 1234,
            reactionCount: 7,
            detailsJSON: #"{"👍":7}"#
        )
        try store.finishRun(
            id: runID,
            status: "success",
            endedAt: Date(timeIntervalSince1970: 1_040),
            durationMilliseconds: 40000,
            articlesFound: 12,
            selectedArticleTitle: "Article",
            selectedArticleURL: "https://example.com/article",
            errorMessage: nil
        )

        let summary = try store.summary()
        XCTAssertEqual(summary.lastRun?.status, "success")
        XCTAssertEqual(summary.lastRun?.articlesFound, 12)
        XCTAssertEqual(summary.totalTokens, 150)
        XCTAssertEqual(summary.latestPost?.messageID, 42)
        XCTAssertEqual(summary.latestEngagement?.subscriberCount, 1234)
        XCTAssertEqual(try store.performance().first?.stepName, "telegram_publish")
    }

    private func temporaryDatabasePath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return directory.appendingPathComponent("metrics.sqlite").path
    }
}

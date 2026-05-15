import Foundation
import SQLite3

public enum MetricsStoreError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
}

public final class SQLiteMetricsStore: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "ios-feed.metrics-store")
    private var database: OpaquePointer?

    public init(path: String) throws {
        self.path = path
        try Self.createParentDirectoryIfNeeded(for: path)

        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw MetricsStoreError.openFailed(message)
        }
        self.database = database
        try migrate()
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    public func startRun(startedAt: Date = Date()) throws -> Int64 {
        try queue.sync {
            try execute(
                """
                INSERT INTO runs (started_at, status, articles_found)
                VALUES (?, 'running', 0)
                """,
                [.double(startedAt.timeIntervalSince1970)]
            )
            return sqlite3_last_insert_rowid(database)
        }
    }

    public func finishRun(
        id: Int64,
        status: String,
        endedAt: Date = Date(),
        durationMilliseconds: Int,
        articlesFound: Int,
        selectedArticleTitle: String?,
        selectedArticleURL: String?,
        errorMessage: String?
    ) throws {
        try queue.sync {
            try execute(
                """
                UPDATE runs
                SET ended_at = ?, status = ?, duration_ms = ?, articles_found = ?,
                    selected_article_title = ?, selected_article_url = ?, error_message = ?
                WHERE id = ?
                """,
                [
                    .double(endedAt.timeIntervalSince1970),
                    .text(status),
                    .int(durationMilliseconds),
                    .int(articlesFound),
                    .optionalText(selectedArticleTitle),
                    .optionalText(selectedArticleURL),
                    .optionalText(errorMessage),
                    .int64(id)
                ]
            )
        }
    }

    public func recordStep(
        runID: Int64,
        name: String,
        durationMilliseconds: Int,
        status: String,
        errorMessage: String? = nil
    ) throws {
        try queue.sync {
            try execute(
                """
                INSERT INTO run_steps (run_id, name, duration_ms, status, error_message)
                VALUES (?, ?, ?, ?, ?)
                """,
                [.int64(runID), .text(name), .int(durationMilliseconds), .text(status), .optionalText(errorMessage)]
            )
        }
    }

    public func recordAICall(
        runID: Int64,
        operation: String,
        model: String,
        usage: OpenAIUsage,
        durationMilliseconds: Int,
        status: String,
        estimatedCostUSD: Double,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) throws {
        try queue.sync {
            try execute(
                """
                INSERT INTO ai_calls (
                    run_id, operation, model, prompt_tokens, completion_tokens, total_tokens,
                    duration_ms, status, estimated_cost_usd, error_message, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int64(runID), .text(operation), .text(model),
                    .int(usage.promptTokens), .int(usage.completionTokens), .int(usage.totalTokens),
                    .int(durationMilliseconds), .text(status), .double(estimatedCostUSD),
                    .optionalText(errorMessage), .double(createdAt.timeIntervalSince1970)
                ]
            )
        }
    }

    public func recordTelegramPost(
        runID: Int64,
        messageID: Int?,
        method: String,
        articleURL: String?,
        title: String?,
        postedAt: Date = Date(),
        status: String,
        errorMessage: String? = nil
    ) throws {
        try queue.sync {
            try execute(
                """
                INSERT INTO telegram_posts (
                    run_id, message_id, method, article_url, title, posted_at, status, error_message
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int64(runID), .optionalInt(messageID), .text(method),
                    .optionalText(articleURL), .optionalText(title),
                    .double(postedAt.timeIntervalSince1970), .text(status), .optionalText(errorMessage)
                ]
            )
        }
    }

    public func recordEngagement(
        messageID: Int,
        capturedAt: Date = Date(),
        subscriberCount: Int?,
        reactionCount: Int?,
        detailsJSON: String?
    ) throws {
        try queue.sync {
            try execute(
                """
                INSERT INTO telegram_engagement (
                    telegram_message_id, captured_at, subscriber_count, reaction_count, details_json
                )
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .int(messageID), .double(capturedAt.timeIntervalSince1970),
                    .optionalInt(subscriberCount), .optionalInt(reactionCount), .optionalText(detailsJSON)
                ]
            )
        }
    }

    public func getState(_ key: String) throws -> String? {
        try queue.sync {
            let rows = try all("SELECT value FROM state WHERE key = ?", [.text(key)]) { statement in
                stringColumn(statement, 0) ?? ""
            }
            return rows.first
        }
    }

    public func setState(_ key: String, value: String) throws {
        try queue.sync {
            try execute(
                """
                INSERT INTO state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                [.text(key), .text(value)]
            )
        }
    }

    public func summary() throws -> DashboardSummary {
        try queue.sync {
            let lastRun = try fetchRuns(limit: 1).first
            let successfulRuns = try scalarInt("SELECT COUNT(*) FROM runs WHERE status = 'success'")
            let failedRuns = try scalarInt("SELECT COUNT(*) FROM runs WHERE status = 'failure'")
            let totalTokens = try scalarInt("SELECT COALESCE(SUM(total_tokens), 0) FROM ai_calls")
            let totalCost = try scalarDouble("SELECT COALESCE(SUM(estimated_cost_usd), 0) FROM ai_calls")
            let latestPost = try fetchTelegramPosts(limit: 1).first
            let latestEngagement = try fetchEngagement(limit: 1).first

            return DashboardSummary(
                generatedAt: Date(),
                lastRun: lastRun,
                successfulRuns: successfulRuns,
                failedRuns: failedRuns,
                totalTokens: totalTokens,
                totalCostUSD: totalCost,
                latestPost: latestPost,
                latestEngagement: latestEngagement
            )
        }
    }

    public func runs(limit: Int = 30) throws -> [RunRecord] {
        try queue.sync {
            try fetchRuns(limit: limit)
        }
    }

    public func aiCalls(limit: Int = 50) throws -> [AICallRecord] {
        try queue.sync {
            try fetchAICalls(limit: limit)
        }
    }

    public func telegramPosts(limit: Int = 30) throws -> [TelegramPostRecord] {
        try queue.sync {
            try fetchTelegramPosts(limit: limit)
        }
    }

    public func engagement(limit: Int = 30) throws -> [EngagementRecord] {
        try queue.sync {
            try fetchEngagement(limit: limit)
        }
    }

    public func costs(days: Int = 30) throws -> [CostPoint] {
        try queue.sync {
            try all(
                """
                SELECT date(created_at, 'unixepoch') AS day,
                       COALESCE(SUM(total_tokens), 0),
                       COALESCE(SUM(estimated_cost_usd), 0)
                FROM ai_calls
                GROUP BY day
                ORDER BY day DESC
                LIMIT ?
                """,
                [.int(days)]
            ) { statement in
                CostPoint(
                    day: stringColumn(statement, 0) ?? "",
                    totalTokens: intColumn(statement, 1),
                    estimatedCostUSD: doubleColumn(statement, 2)
                )
            }
        }
    }

    public func performance(limit: Int = 30) throws -> [PerformancePoint] {
        try queue.sync {
            try all(
                """
                SELECT name, CAST(AVG(duration_ms) AS INTEGER), MAX(duration_ms)
                FROM run_steps
                GROUP BY name
                ORDER BY AVG(duration_ms) DESC
                LIMIT ?
                """,
                [.int(limit)]
            ) { statement in
                PerformancePoint(
                    stepName: stringColumn(statement, 0) ?? "",
                    averageDurationMilliseconds: intColumn(statement, 1),
                    maxDurationMilliseconds: intColumn(statement, 2)
                )
            }
        }
    }

    private func migrate() throws {
        try queue.sync {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS runs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    status TEXT NOT NULL,
                    duration_ms INTEGER,
                    articles_found INTEGER NOT NULL DEFAULT 0,
                    selected_article_title TEXT,
                    selected_article_url TEXT,
                    error_message TEXT
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS run_steps (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    error_message TEXT,
                    FOREIGN KEY(run_id) REFERENCES runs(id)
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS ai_calls (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id INTEGER NOT NULL,
                    operation TEXT NOT NULL,
                    model TEXT NOT NULL,
                    prompt_tokens INTEGER NOT NULL,
                    completion_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    estimated_cost_usd REAL NOT NULL,
                    error_message TEXT,
                    created_at REAL NOT NULL,
                    FOREIGN KEY(run_id) REFERENCES runs(id)
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS telegram_posts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id INTEGER NOT NULL,
                    message_id INTEGER,
                    method TEXT NOT NULL,
                    article_url TEXT,
                    title TEXT,
                    posted_at REAL NOT NULL,
                    status TEXT NOT NULL,
                    error_message TEXT,
                    FOREIGN KEY(run_id) REFERENCES runs(id)
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS telegram_engagement (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    telegram_message_id INTEGER NOT NULL,
                    captured_at REAL NOT NULL,
                    subscriber_count INTEGER,
                    reaction_count INTEGER,
                    details_json TEXT
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                )
                """
            )
        }
    }

    private func fetchRuns(limit: Int) throws -> [RunRecord] {
        try all(
            """
            SELECT id, started_at, ended_at, status, duration_ms, articles_found,
                   selected_article_title, selected_article_url, error_message
            FROM runs
            ORDER BY started_at DESC
            LIMIT ?
            """,
            [.int(limit)]
        ) { statement in
            RunRecord(
                id: int64Column(statement, 0),
                startedAt: dateColumn(statement, 1) ?? Date(timeIntervalSince1970: 0),
                endedAt: dateColumn(statement, 2),
                status: stringColumn(statement, 3) ?? "",
                durationMilliseconds: optionalIntColumn(statement, 4),
                articlesFound: intColumn(statement, 5),
                selectedArticleTitle: stringColumn(statement, 6),
                selectedArticleURL: stringColumn(statement, 7),
                errorMessage: stringColumn(statement, 8)
            )
        }
    }

    private func fetchAICalls(limit: Int) throws -> [AICallRecord] {
        try all(
            """
            SELECT operation, model, prompt_tokens, completion_tokens, total_tokens,
                   duration_ms, status, estimated_cost_usd, error_message, created_at
            FROM ai_calls
            ORDER BY created_at DESC
            LIMIT ?
            """,
            [.int(limit)]
        ) { statement in
            AICallRecord(
                operation: stringColumn(statement, 0) ?? "",
                model: stringColumn(statement, 1) ?? "",
                promptTokens: intColumn(statement, 2),
                completionTokens: intColumn(statement, 3),
                totalTokens: intColumn(statement, 4),
                durationMilliseconds: intColumn(statement, 5),
                status: stringColumn(statement, 6) ?? "",
                estimatedCostUSD: doubleColumn(statement, 7),
                errorMessage: stringColumn(statement, 8),
                createdAt: dateColumn(statement, 9) ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    private func fetchTelegramPosts(limit: Int) throws -> [TelegramPostRecord] {
        try all(
            """
            SELECT message_id, method, article_url, title, posted_at, status, error_message
            FROM telegram_posts
            ORDER BY posted_at DESC
            LIMIT ?
            """,
            [.int(limit)]
        ) { statement in
            TelegramPostRecord(
                messageID: optionalIntColumn(statement, 0),
                method: stringColumn(statement, 1) ?? "",
                articleURL: stringColumn(statement, 2),
                title: stringColumn(statement, 3),
                postedAt: dateColumn(statement, 4) ?? Date(timeIntervalSince1970: 0),
                status: stringColumn(statement, 5) ?? "",
                errorMessage: stringColumn(statement, 6)
            )
        }
    }

    private func fetchEngagement(limit: Int) throws -> [EngagementRecord] {
        try all(
            """
            SELECT telegram_message_id, captured_at, subscriber_count, reaction_count, details_json
            FROM telegram_engagement
            ORDER BY captured_at DESC
            LIMIT ?
            """,
            [.int(limit)]
        ) { statement in
            EngagementRecord(
                messageID: intColumn(statement, 0),
                capturedAt: dateColumn(statement, 1) ?? Date(timeIntervalSince1970: 0),
                subscriberCount: optionalIntColumn(statement, 2),
                reactionCount: optionalIntColumn(statement, 3),
                detailsJSON: stringColumn(statement, 4)
            )
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try first(sql) { intColumn($0, 0) } ?? 0
    }

    private func scalarDouble(_ sql: String) throws -> Double {
        try first(sql) { doubleColumn($0, 0) } ?? 0
    }

    private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MetricsStoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return
            }
            if result != SQLITE_ROW {
                throw MetricsStoreError.executeFailed(errorMessage)
            }
        }
    }

    private func all<T>(_ sql: String, _ bindings: [Binding] = [], map: (OpaquePointer?) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MetricsStoreError.prepareFailed(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(try map(statement))
        }
        return rows
    }

    private func first<T>(_ sql: String, _ bindings: [Binding] = [], map: (OpaquePointer?) throws -> T) throws -> T? {
        try all(sql, bindings, map: map).first
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer?) throws {
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch binding {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .int(let value):
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case .int64(let value):
                result = sqlite3_bind_int64(statement, position, sqlite3_int64(value))
            case .double(let value):
                result = sqlite3_bind_double(statement, position, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1, sqliteTransient)
            }

            guard result == SQLITE_OK else {
                throw MetricsStoreError.executeFailed(errorMessage)
            }
        }
    }

    private var errorMessage: String {
        guard let database else { return "database is closed" }
        return String(cString: sqlite3_errmsg(database))
    }

    private static func createParentDirectoryIfNeeded(for path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        guard !directory.path.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

private enum Binding {
    case null
    case int(Int)
    case int64(Int64)
    case double(Double)
    case text(String)

    static func optionalText(_ value: String?) -> Binding {
        value.map(Binding.text) ?? .null
    }

    static func optionalInt(_ value: Int?) -> Binding {
        value.map(Binding.int) ?? .null
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func stringColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let text = sqlite3_column_text(statement, index) else {
        return nil
    }
    return String(cString: text)
}

private func intColumn(_ statement: OpaquePointer?, _ index: Int32) -> Int {
    Int(sqlite3_column_int64(statement, index))
}

private func optionalIntColumn(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : intColumn(statement, index)
}

private func int64Column(_ statement: OpaquePointer?, _ index: Int32) -> Int64 {
    Int64(sqlite3_column_int64(statement, index))
}

private func doubleColumn(_ statement: OpaquePointer?, _ index: Int32) -> Double {
    sqlite3_column_double(statement, index)
}

private func dateColumn(_ statement: OpaquePointer?, _ index: Int32) -> Date? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
}

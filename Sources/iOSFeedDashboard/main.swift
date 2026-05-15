import Foundation
import iOSFeedMetrics

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum DashboardConfig {
    static let databasePath = ProcessInfo.processInfo.environment["METRICS_DB_PATH"] ?? ".build/metrics.sqlite"
    static let host = ProcessInfo.processInfo.environment["DASHBOARD_HOST"] ?? "0.0.0.0"
    static let port = UInt16(ProcessInfo.processInfo.environment["DASHBOARD_PORT"] ?? "8080") ?? 8080
    static let username = ProcessInfo.processInfo.environment["DASHBOARD_USERNAME"] ?? ""
    static let password = ProcessInfo.processInfo.environment["DASHBOARD_PASSWORD"] ?? ""

    static func validate() {
        let missing = [
            ("DASHBOARD_USERNAME", username),
            ("DASHBOARD_PASSWORD", password)
        ].filter { $0.1.isEmpty }.map { $0.0 }

        if !missing.isEmpty {
            FileHandle.standardError.write(Data("Missing dashboard configuration: \(missing.joined(separator: ", "))\n".utf8))
            Foundation.exit(1)
        }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
}

final class DashboardServer: @unchecked Sendable {
    private let store: SQLiteMetricsStore
    private let encoder: JSONEncoder

    init(store: SQLiteMetricsStore) {
        self.store = store
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func start(host: String, port: UInt16) throws {
        let serverSocket = socket(AF_INET, socketStreamType, 0)
        guard serverSocket >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { closeSocket(serverSocket) }

        var reuse = Int32(1)
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: internetAddress(host))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE) }
        guard listen(serverSocket, 32) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        print("Dashboard listening on http://\(host):\(port)")

        while true {
            let client = accept(serverSocket, nil, nil)
            guard client >= 0 else { continue }
            DispatchQueue.global().async {
                self.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        defer { closeSocket(client) }

        guard let request = readRequest(from: client) else {
            write(response: response(status: "400 Bad Request", body: "Bad Request"), to: client)
            return
        }

        guard isAuthorized(request) else {
            write(response: response(
                status: "401 Unauthorized",
                headers: ["WWW-Authenticate": "Basic realm=\"iOS Feed Metrics\""],
                body: "Unauthorized"
            ), to: client)
            return
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/"):
                write(response: response(contentType: "text/html; charset=utf-8", body: dashboardHTML), to: client)
            case ("GET", "/api/summary"):
                try writeJSON(store.summary(), to: client)
            case ("GET", "/api/runs"):
                try writeJSON(store.runs(), to: client)
            case ("GET", "/api/tokens"):
                try writeJSON(store.aiCalls(), to: client)
            case ("GET", "/api/costs"):
                try writeJSON(store.costs(), to: client)
            case ("GET", "/api/performance"):
                try writeJSON(store.performance(), to: client)
            case ("GET", "/api/engagement"):
                try writeJSON(store.engagement(), to: client)
            case ("GET", "/api/posts"):
                try writeJSON(store.telegramPosts(), to: client)
            default:
                write(response: response(status: "404 Not Found", body: "Not Found"), to: client)
            }
        } catch {
            write(response: response(status: "500 Internal Server Error", body: String(describing: error)), to: client)
        }
    }

    private func writeJSON<Value: Encodable>(_ value: Value, to client: Int32) throws {
        let data = try encoder.encode(value)
        write(response: response(contentType: "application/json", body: data), to: client)
    }

    private func readRequest(from client: Int32) -> HTTPRequest? {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = recv(client, &buffer, buffer.count, 0)
        guard count > 0, let raw = String(bytes: buffer.prefix(count), encoding: .utf8) else { return nil }

        let lines = raw.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let fullPath = String(requestParts[1])
        let path = fullPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? fullPath
        return HTTPRequest(method: String(requestParts[0]), path: path, headers: headers)
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"],
              header.hasPrefix("Basic ") else {
            return false
        }
        let token = String(header.dropFirst("Basic ".count))
        let expected = "\(DashboardConfig.username):\(DashboardConfig.password)"
            .data(using: .utf8)?
            .base64EncodedString()
        return token == expected
    }

    private func response(
        status: String = "200 OK",
        headers: [String: String] = [:],
        contentType: String = "text/plain; charset=utf-8",
        body: String
    ) -> Data {
        response(status: status, headers: headers, contentType: contentType, body: Data(body.utf8))
    }

    private func response(
        status: String = "200 OK",
        headers: [String: String] = [:],
        contentType: String = "text/plain; charset=utf-8",
        body: Data
    ) -> Data {
        var lines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        for (name, value) in headers {
            lines.append("\(name): \(value)")
        }
        lines.append("")
        lines.append("")

        var data = Data(lines.joined(separator: "\r\n").utf8)
        data.append(body)
        return data
    }

    private func write(response: Data, to client: Int32) {
        response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = send(client, baseAddress, response.count, 0)
        }
    }
}

#if os(Linux)
private let socketStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let socketStreamType = SOCK_STREAM
#endif

private func closeSocket(_ descriptor: Int32) {
    #if os(Linux)
    _ = Glibc.close(descriptor)
    #else
    _ = Darwin.close(descriptor)
    #endif
}

private func internetAddress(_ host: String) -> UInt32 {
    if host == "0.0.0.0" {
        return INADDR_ANY.bigEndian
    }
    return inet_addr(host)
}

private let dashboardHTML = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>iOS Feed Metrics</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #f7f8fb;
      --panel: #ffffff;
      --text: #17202a;
      --muted: #637083;
      --line: #d9dee8;
      --accent: #0a7cff;
      --good: #16833a;
      --bad: #bd2c2c;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #101317;
        --panel: #181d24;
        --text: #f0f3f7;
        --muted: #a4adba;
        --line: #303846;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 24px clamp(16px, 4vw, 48px);
      border-bottom: 1px solid var(--line);
      background: var(--panel);
    }
    h1 { margin: 0; font-size: 24px; letter-spacing: 0; }
    main { padding: 24px clamp(16px, 4vw, 48px) 48px; }
    .muted { color: var(--muted); }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
      gap: 12px;
      margin-bottom: 24px;
    }
    .card {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
      min-height: 96px;
    }
    .label { color: var(--muted); font-size: 12px; text-transform: uppercase; }
    .value { margin-top: 8px; font-size: 28px; font-weight: 700; overflow-wrap: anywhere; }
    section {
      margin-top: 24px;
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      overflow: hidden;
    }
    section h2 { margin: 0; padding: 16px; font-size: 17px; border-bottom: 1px solid var(--line); }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 10px 12px; border-bottom: 1px solid var(--line); text-align: left; vertical-align: top; }
    th { color: var(--muted); font-size: 12px; font-weight: 600; }
    tr:last-child td { border-bottom: 0; }
    .status-success { color: var(--good); font-weight: 700; }
    .status-failure { color: var(--bad); font-weight: 700; }
    .bar {
      height: 8px;
      background: var(--line);
      border-radius: 999px;
      overflow: hidden;
      min-width: 100px;
    }
    .bar span { display: block; height: 100%; background: var(--accent); }
  </style>
</head>
<body>
  <header>
    <div>
      <h1>iOS Feed Metrics</h1>
      <div class="muted" id="updated">Loading...</div>
    </div>
    <div class="muted">Auto-refresh: 5s</div>
  </header>
  <main>
    <div class="grid">
      <div class="card"><div class="label">Last run</div><div class="value" id="lastRun">-</div></div>
      <div class="card"><div class="label">Articles</div><div class="value" id="articles">-</div></div>
      <div class="card"><div class="label">Tokens</div><div class="value" id="tokens">-</div></div>
      <div class="card"><div class="label">Cost</div><div class="value" id="cost">-</div></div>
      <div class="card"><div class="label">Latest post</div><div class="value" id="post">-</div></div>
      <div class="card"><div class="label">Engagement</div><div class="value" id="engagement">-</div></div>
    </div>

    <section>
      <h2>Recent Runs</h2>
      <table><thead><tr><th>Started</th><th>Status</th><th>Duration</th><th>Articles</th><th>Selected</th><th>Error</th></tr></thead><tbody id="runs"></tbody></table>
    </section>

    <section>
      <h2>Tokens and Pricing</h2>
      <table><thead><tr><th>Operation</th><th>Model</th><th>Tokens</th><th>Cost</th><th>Duration</th><th>Status</th></tr></thead><tbody id="aiCalls"></tbody></table>
    </section>

    <section>
      <h2>Performance</h2>
      <table><thead><tr><th>Step</th><th>Average</th><th>Max</th><th></th></tr></thead><tbody id="performance"></tbody></table>
    </section>
  </main>
  <script>
    const fmtDate = value => value ? new Date(value).toLocaleString() : '-';
    const fmtMs = value => value == null ? '-' : `${value} ms`;
    const fmtCost = value => `$${Number(value || 0).toFixed(4)}`;
    const statusClass = value => value === 'success' ? 'status-success' : value === 'failure' ? 'status-failure' : '';

    async function getJSON(path) {
      const response = await fetch(path, { cache: 'no-store' });
      if (!response.ok) throw new Error(`${path}: ${response.status}`);
      return response.json();
    }

    function row(cells) {
      return `<tr>${cells.map(cell => `<td>${cell}</td>`).join('')}</tr>`;
    }

    async function refresh() {
      const [summary, runs, aiCalls, performance] = await Promise.all([
        getJSON('/api/summary'),
        getJSON('/api/runs'),
        getJSON('/api/tokens'),
        getJSON('/api/performance')
      ]);

      document.getElementById('updated').textContent = `Updated ${fmtDate(summary.generatedAt)}`;
      document.getElementById('lastRun').textContent = summary.lastRun?.status || '-';
      document.getElementById('articles').textContent = summary.lastRun?.articlesFound ?? '-';
      document.getElementById('tokens').textContent = Number(summary.totalTokens || 0).toLocaleString();
      document.getElementById('cost').textContent = fmtCost(summary.totalCostUSD);
      document.getElementById('post').textContent = summary.latestPost?.messageID ? `#${summary.latestPost.messageID}` : '-';
      const engagement = summary.latestEngagement;
      document.getElementById('engagement').textContent = engagement
        ? `${engagement.subscriberCount ?? '-'} subs${engagement.reactionCount == null ? '' : `, ${engagement.reactionCount} reactions`}`
        : '-';

      document.getElementById('runs').innerHTML = runs.map(run => row([
        fmtDate(run.startedAt),
        `<span class="${statusClass(run.status)}">${run.status}</span>`,
        fmtMs(run.durationMilliseconds),
        run.articlesFound,
        run.selectedArticleTitle || '-',
        run.errorMessage || ''
      ])).join('');

      document.getElementById('aiCalls').innerHTML = aiCalls.map(call => row([
        call.operation,
        call.model,
        Number(call.totalTokens || 0).toLocaleString(),
        fmtCost(call.estimatedCostUSD),
        fmtMs(call.durationMilliseconds),
        `<span class="${statusClass(call.status)}">${call.status}</span>`
      ])).join('');

      const max = Math.max(1, ...performance.map(item => item.maxDurationMilliseconds));
      document.getElementById('performance').innerHTML = performance.map(item => row([
        item.stepName,
        fmtMs(item.averageDurationMilliseconds),
        fmtMs(item.maxDurationMilliseconds),
        `<div class="bar"><span style="width:${Math.max(2, item.maxDurationMilliseconds / max * 100)}%"></span></div>`
      ])).join('');
    }

    refresh().catch(error => document.getElementById('updated').textContent = error.message);
    setInterval(() => refresh().catch(console.error), 5000);
  </script>
</body>
</html>
"""

DashboardConfig.validate()
let store = try SQLiteMetricsStore(path: DashboardConfig.databasePath)
let server = DashboardServer(store: store)
try server.start(host: DashboardConfig.host, port: DashboardConfig.port)

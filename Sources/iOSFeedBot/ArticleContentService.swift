import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cheap signals about an article's body, so selection can judge substance instead of the feed blurb.
struct ArticlePreview: Sendable, Equatable {
    let wordCount: Int
    let codeBlockCount: Int
    let excerpt: String
}

struct ArticleContentService {
    /// Forum text kept ahead of an attached proposal, so the proposal fits the prompt limit.
    private static let maxForumCharacters = 3_000
    private static let maxExcerptCharacters = 300
    /// Bounds the selection prompt and the number of page fetches per run.
    static let maxPreviews = 40

    /// Previews keyed by article URL; pages that fail to load are left out.
    func fetchPreviews(for articles: [Article]) async -> [String: ArticlePreview] {
        await withTaskGroup(of: (String, ArticlePreview?).self) { group in
            for article in articles.prefix(Self.maxPreviews) {
                group.addTask {
                    guard let html = await fetchString(from: article.url) else { return (article.url, nil) }
                    return (article.url, Self.preview(fromHTML: html))
                }
            }
            var previews: [String: ArticlePreview] = [:]
            for await (url, preview) in group {
                previews[url] = preview
            }
            return previews
        }
    }

    static func preview(fromHTML html: String) -> ArticlePreview? {
        let body = mainHTML(in: html)
        let text = extractReadableText(from: body)
        guard !text.isEmpty else { return nil }
        let codeBlockCount = body.ranges(of: /(?i)<pre\b/).count
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let excerpt = text.replacingOccurrences(of: "\n", with: " ").prefix(maxExcerptCharacters)
        return ArticlePreview(wordCount: wordCount, codeBlockCount: codeBlockCount, excerpt: String(excerpt))
    }

    /// The `<article>` (or `<main>`) region, so sidebars, comments and related-post lists don't
    /// inflate the counts. Falls back to the whole page when the region is missing or nearly empty.
    static func mainHTML(in html: String) -> String {
        for tag in ["article", "main"] {
            guard let open = html.range(of: "<\(tag)\\b[^>]*>", options: [.regularExpression, .caseInsensitive]),
                  let close = html.range(of: "</\(tag)>", options: [.caseInsensitive, .backwards]),
                  open.upperBound < close.lowerBound else { continue }
            let region = String(html[open.upperBound..<close.lowerBound])
            if extractReadableText(from: region).count >= 300 {
                return region
            }
        }
        return html
    }

    func fetchContent(for urlString: String) async -> String? {
        guard let html = await fetchString(from: urlString) else { return nil }

        let content = Self.extractReadableText(from: html)
        guard !content.isEmpty else { return nil }

        // Swift Forums review/acceptance threads are boilerplate around a link: attach the proposal itself.
        if urlString.contains("forums.swift.org"),
           let proposalURL = Self.proposalRawURL(in: html),
           let proposal = await fetchString(from: proposalURL) {
            return """
            Forum announcement:
            \(content.prefix(Self.maxForumCharacters))

            Proposal:
            \(proposal)
            """
        }
        return content
    }

    private func fetchString(from urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        request.setValue("iOSFeedBot/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(data: data, encoding: .utf8)
        } catch {
            print("Failed to fetch article content for \(urlString): \(error)")
            return nil
        }
    }

    /// Raw GitHub URL of the first swift-evolution proposal linked from the page.
    static func proposalRawURL(in html: String) -> String? {
        let pattern = "https://github\\.com/swiftlang/swift-evolution/blob/([^/\"'\\s]+)/(proposals/[^\"'\\s#?<]+\\.md)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let branch = Range(match.range(at: 1), in: html),
              let path = Range(match.range(at: 2), in: html) else {
            return nil
        }
        return "https://raw.githubusercontent.com/swiftlang/swift-evolution/\(html[branch])/\(html[path])"
    }

    static func extractReadableText(from html: String) -> String {
        var text = html

        let removablePatterns = [
            "<script\\b[^>]*>[\\s\\S]*?</script>",
            "<style\\b[^>]*>[\\s\\S]*?</style>",
            "<noscript\\b[^>]*>[\\s\\S]*?</noscript>",
            "<svg\\b[^>]*>[\\s\\S]*?</svg>",
            "<nav\\b[^>]*>[\\s\\S]*?</nav>",
            "<header\\b[^>]*>[\\s\\S]*?</header>",
            "<footer\\b[^>]*>[\\s\\S]*?</footer>"
        ]

        for pattern in removablePatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }

        let blockPatterns = [
            "</p>", "</div>", "</section>", "</article>", "</main>",
            "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
            "<br\\s*/?>", "</li>"
        ]

        for pattern in blockPatterns {
            text = text.replacingOccurrences(of: pattern, with: "\n", options: [.regularExpression, .caseInsensitive])
        }

        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = decodeHTMLEntities(in: text)
        text = text.replacingOccurrences(of: "[ \\t\\r\\f\\v]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: " *\\n+ *", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(in text: String) -> String {
        var decoded = text
        let namedEntities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " "
        ]

        for (entity, value) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: value)
        }

        decoded = replaceNumericEntities(in: decoded, pattern: "&#(\\d+);", radix: 10)
        decoded = replaceNumericEntities(in: decoded, pattern: "&#x([0-9a-fA-F]+);", radix: 16)

        return decoded
    }

    private static func replaceNumericEntities(in text: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()

        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let valueRange = Range(match.range(at: 1), in: result),
                  let scalarValue = UInt32(result[valueRange], radix: radix),
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }

            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }

        return result
    }
}

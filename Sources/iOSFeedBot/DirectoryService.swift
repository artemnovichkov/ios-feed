import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DirectoryService: Sendable {
    enum DirectoryError: Error {
        case invalidResponse
    }

    /// Directory categories that never contain technical content.
    static let excludedCategorySlugs: Set<String> = ["marketing"]

    func fetchBlogs() async throws -> [Blog] {
        guard let url = URL(string: Config.directoryUrl) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("iOSFeedBot/1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DirectoryError.invalidResponse
        }
        
        return try Self.parseBlogs(from: data)
    }

    static func parseBlogs(
        from data: Data,
        languageCode: String = "en",
        excludingCategorySlugs excludedSlugs: Set<String> = excludedCategorySlugs
    ) throws -> [Blog] {
        let languages = try JSONDecoder().decode([DirectoryLanguage].self, from: data)
        return languages
            .filter { $0.language == languageCode }
            .flatMap { $0.categories }
            .filter { !excludedSlugs.contains($0.slug ?? "") }
            .flatMap { $0.sites }
            .filter { $0.feedUrl != nil }
    }
}

private struct DirectoryLanguage: Codable {
    let language: String
    let categories: [DirectoryCategory]
}

private struct DirectoryCategory: Codable {
    let slug: String?
    let sites: [Blog]
}

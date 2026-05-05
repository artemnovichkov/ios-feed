import Foundation

class DirectoryService {
    enum DirectoryError: Error {
        case invalidResponse
    }

    func fetchBlogs() async throws -> [Blog] {
        guard let url = URL(string: Config.directoryUrl) else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DirectoryError.invalidResponse
        }
        
        struct Language: Codable {
            let categories: [Category]
        }
        
        struct Category: Codable {
            let sites: [Blog]
        }
        
        let languages = try JSONDecoder().decode([Language].self, from: data)
        return languages
            .flatMap { $0.categories }
            .flatMap { $0.sites }
            .filter { $0.feedUrl != nil }
    }
}

import Foundation

class DirectoryService {
    func fetchBlogs() async throws -> [Blog] {
        guard let url = URL(string: Config.directoryUrl) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        
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
    }
}

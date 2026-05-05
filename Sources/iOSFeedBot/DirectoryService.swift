import Foundation

class DirectoryService {
    func fetchBlogs() async throws -> [Blog] {
        guard let url = URL(string: Config.directoryUrl) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // The blogs.json structure is an array of categories, each having a 'blogs' array
        struct Category: Codable {
            let blogs: [Blog]
        }
        let categories = try JSONDecoder().decode([Category].self, from: data)
        return categories.flatMap { $0.blogs }
    }
}

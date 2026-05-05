import Foundation

do {
    Config.validate()
    
    let directoryService = DirectoryService()
    print("Fetching blog directory...")
    let blogs = try await directoryService.fetchBlogs()
    print("Successfully fetched \(blogs.count) blogs.")
    
    if let first = blogs.first {
        print("First blog: \(first.title) (\(first.siteUrl))")
    }
} catch {
    print("Error: \(error)")
    exit(1)
}

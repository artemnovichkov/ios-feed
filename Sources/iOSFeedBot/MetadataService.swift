import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MetadataService: Sendable {
    func fetchOGImageURL(for urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("iOSFeedBot/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            
            // Look for <meta property="og:image" content="...">
            let patterns = [
                "<meta[^>]+property=\"og:image\"[^>]+content=\"([^\"]+)\"",
                "<meta[^>]+content=\"([^\"]+)\"[^>]+property=\"og:image\""
            ]
            
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)) {
                    if let range = Range(match.range(at: 1), in: html) {
                        return String(html[range])
                    }
                }
            }
        } catch {
            print("Failed to fetch OG image for \(urlString): \(error)")
        }
        
        return nil
    }
}

import Foundation

struct WiskGoogleFontClient {
    var session: URLSession = .shared

    func search(_ query: String) -> [WiskGoogleFont] {
        WiskGoogleFontCatalog.search(query)
    }

    func downloadFont(for font: WiskGoogleFont, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let css = try await fetchCSS(from: font.cssURL)
        let fontURL = try Self.firstFontURL(in: css)
        let (data, _) = try await session.data(from: fontURL)
        let fileName = "\(Self.slug(font.family))-\(font.variant).\(fontURL.pathExtension.isEmpty ? "font" : fontURL.pathExtension)"
        let destinationURL = directory.appendingPathComponent(fileName)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    func fetchCSS(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WiskGoogleFontError.requestFailed
        }
        guard let css = String(data: data, encoding: .utf8) else {
            throw WiskGoogleFontError.invalidCSS
        }
        return css
    }

    static func firstFontURL(in css: String) throws -> URL {
        let pattern = #"url\((https:[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)),
              let range = Range(match.range(at: 1), in: css),
              let url = URL(string: String(css[range])) else {
            throw WiskGoogleFontError.missingFontURL
        }
        return url
    }

    private static func slug(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

private enum WiskGoogleFontError: LocalizedError {
    case requestFailed
    case invalidCSS
    case missingFontURL

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "Wisk could not reach Google Fonts."
        case .invalidCSS:
            return "Wisk could not read the Google Fonts response."
        case .missingFontURL:
            return "Wisk could not find a downloadable font file from Google Fonts."
        }
    }
}

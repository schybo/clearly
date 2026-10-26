import Foundation

enum WiskAPIConfiguration {
    static let userDefaultsKey = "wisk.sync.baseURL"
    static let environmentKey = "WISK_API_BASE_URL"
    static let localDevelopmentURL = URL(string: "http://127.0.0.1:4010")!
    /// Vercel project `mira-api` (renamed from Mira, still serving `wisk-api`).
    static let productionURL = URL(string: "https://mira-api-nine.vercel.app")!

    static func resolvedBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> URL {
        if let url = url(from: environment[environmentKey]) {
            return url
        }
        if let url = url(from: defaults.string(forKey: userDefaultsKey)) {
            return url
        }
        return productionURL
    }

    static func url(from raw: String?) -> URL? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

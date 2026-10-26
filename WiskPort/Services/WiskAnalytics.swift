import Foundation

enum WiskAnalytics {
    private static let host = URL(string: "https://us.i.posthog.com/capture/")!

    static func track(_ event: String, properties: [String: String] = [:]) {
        guard !Secrets.postHogAPIKey.isEmpty else { return }
        var eventProperties = properties
        eventProperties["app"] = "wisk"
        eventProperties["platform"] = "ios"
        eventProperties["environment"] = "production"
        eventProperties["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        eventProperties["build"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        let payload: [String: Any] = [
            "api_key": Secrets.postHogAPIKey,
            "event": event,
            "distinct_id": distinctID,
            "properties": eventProperties
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: host)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    private static var distinctID: String {
        let key = "wisk_analytics_distinct_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

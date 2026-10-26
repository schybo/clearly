import Foundation
import SwiftUI

enum WiskEditorFontSource: String, Codable {
    case builtIn
    case local
    case google
}

struct WiskEditorFontSelection: Codable, Equatable, Identifiable {
    var source: WiskEditorFontSource
    var builtInRawValue: String?
    var displayName: String
    var postScriptName: String?
    var localFileName: String?
    var googleFamily: String?
    var googleVariant: String?
    var googleCSSURL: URL?

    var id: String {
        switch source {
        case .builtIn:
            return "builtIn:\(builtInRawValue ?? WiskEditorFontFamily.system.rawValue)"
        case .local:
            return "local:\(localFileName ?? displayName)"
        case .google:
            return "google:\(googleFamily ?? displayName):\(googleVariant ?? "regular")"
        }
    }

    var title: String {
        displayName
    }

    var description: String {
        switch source {
        case .builtIn:
            return builtInFont.description
        case .local:
            return "Imported on this device. Local font files are not synced."
        case .google:
            return "Google Fonts selection synced by family and variant."
        }
    }

    var builtInFont: WiskEditorFontFamily {
        WiskEditorFontFamily(rawValue: builtInRawValue ?? "") ?? .system
    }

    static let system = WiskEditorFontSelection(builtIn: .system)

    init(builtIn: WiskEditorFontFamily) {
        source = .builtIn
        builtInRawValue = builtIn.rawValue
        displayName = builtIn.title
    }

    init(localDisplayName: String, postScriptName: String, fileName: String) {
        source = .local
        displayName = localDisplayName
        self.postScriptName = postScriptName
        localFileName = fileName
    }

    init(googleFont: WiskGoogleFont, postScriptName: String, fileName: String) {
        source = .google
        displayName = googleFont.family
        self.postScriptName = postScriptName
        localFileName = fileName
        googleFamily = googleFont.family
        googleVariant = googleFont.variant
        googleCSSURL = googleFont.cssURL
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch source {
        case .builtIn:
            return builtInFont.font(size: size, weight: weight)
        case .local, .google:
            guard let postScriptName, !postScriptName.isEmpty else {
                return WiskEditorFontFamily.system.font(size: size, weight: weight)
            }
            return .custom(postScriptName, size: size).weight(weight)
        }
    }

    func encodedString() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(from rawValue: String?) -> WiskEditorFontSelection? {
        guard let rawValue, let data = rawValue.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WiskEditorFontSelection.self, from: data)
    }
}

struct WiskGoogleFont: Codable, Equatable, Identifiable {
    var family: String
    var variant: String
    var cssURL: URL

    var id: String {
        "\(family)-\(variant)"
    }

    var title: String {
        family
    }

    var subtitle: String {
        variant == "regular" ? "Regular" : variant.capitalized
    }
}

enum WiskGoogleFontCatalog {
    static let featured: [WiskGoogleFont] = [
        font("Inter"),
        font("Merriweather"),
        font("Lora"),
        font("Source Serif 4"),
        font("Source Sans 3"),
        font("Roboto Slab"),
        font("Nunito"),
        font("IBM Plex Mono"),
        font("JetBrains Mono"),
        font("Libre Baskerville"),
    ]

    static func search(_ query: String) -> [WiskGoogleFont] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return featured }
        return featured.filter { $0.family.localizedCaseInsensitiveContains(trimmed) }
    }

    private static func font(_ family: String, variant: String = "regular") -> WiskGoogleFont {
        let familyQuery = family.replacingOccurrences(of: " ", with: "+")
        let suffix = variant == "regular" ? "" : ":wght@\(variant)"
        let url = URL(string: "https://fonts.googleapis.com/css2?family=\(familyQuery)\(suffix)&display=swap")!
        return WiskGoogleFont(family: family, variant: variant, cssURL: url)
    }
}
